import Foundation

/// Turns the parametric model into concrete numbers, collecting diagnostics.
///
/// This is the *only* place expressions become geometry. Nothing here writes
/// back into the model, so a resolve is pure and repeatable — which is what
/// makes the parametric edit path safe.
public enum ModelResolver {
    public static func resolve(_ state: CADModelState) -> ResolvedModel {
        var diagnostics: [Diagnostic] = []

        let variables = VariableResolver.resolve(state.variables)
        diagnostics.append(contentsOf: variables.diagnostics)

        let materialIDs = Set(state.materials.map(\.id))
        if !materialIDs.contains(MaterialLibrary.defaultMaterialID) {
            diagnostics.append(
                .warning(
                    .project,
                    field: "materials",
                    "The default material (vacuum) is missing from the library; unassigned bodies will fall back to a built-in vacuum definition."
                )
            )
        }

        var bodies: [ResolvedBody] = []
        var failedBodyIDs: Set<UUID> = []

        for (index, body) in state.bodies.enumerated() {
            let outcome = resolveBody(body, orderIndex: index, variables: variables.values)
            diagnostics.append(contentsOf: outcome.diagnostics)

            if let resolved = outcome.body {
                bodies.append(resolved)
            } else {
                failedBodyIDs.insert(body.id)
            }

            if let materialID = body.materialID, !materialIDs.contains(materialID) {
                diagnostics.append(
                    .error(
                        .body(body.id),
                        field: "materialID",
                        "Assigned material no longer exists. The body will use vacuum."
                    )
                )
            }
        }

        diagnostics.append(contentsOf: nameCollisionDiagnostics(state.bodies))
        diagnostics.append(contentsOf: priorityDiagnostics(bodies: bodies))

        let simulationOutcome = resolveSimulation(
            state.simulation,
            variables: variables.values,
            modelBounds: BodyBounds.union(of: bodies.filter(\.isVisible).map(\.axisAlignedBounds)),
            materials: state.materials,
            lengthUnit: state.lengthUnit
        )
        diagnostics.append(contentsOf: simulationOutcome.diagnostics)

        return ResolvedModel(
            variables: variables,
            bodies: bodies,
            failedBodyIDs: failedBodyIDs,
            simulation: simulationOutcome.simulation,
            diagnostics: diagnostics
        )
    }

    // MARK: - Bodies

    private struct BodyOutcome {
        var body: ResolvedBody?
        var diagnostics: [Diagnostic]
    }

    private static func resolveBody(
        _ body: CADBody,
        orderIndex: Int,
        variables: [String: Double]
    ) -> BodyOutcome {
        var diagnostics: [Diagnostic] = []
        let subject = Diagnostic.Subject.body(body.id)

        func scalar(_ expression: Expression, field: String) -> Double? {
            do {
                return try expression.value(variables: variables)
            } catch {
                let message = (error as? ExpressionError)?.description ?? "Invalid expression."
                diagnostics.append(.error(subject, field: field, message))
                return nil
            }
        }

        func vector(_ expression: Vector3Expression, field: String) -> Vec3? {
            let x = scalar(expression.x, field: "\(field).x")
            let y = scalar(expression.y, field: "\(field).y")
            let z = scalar(expression.z, field: "\(field).z")
            guard let x, let y, let z else { return nil }
            return Vec3(x: x, y: y, z: z)
        }

        let shape: ResolvedShape?

        switch body.primitive {
        case .box(let spec):
            let width = scalar(spec.width, field: "primitive.width")
            let height = scalar(spec.height, field: "primitive.height")
            let depth = scalar(spec.depth, field: "primitive.depth")
            if let width, let height, let depth {
                let size = Vec3(x: width, y: height, z: depth)
                diagnostics.append(
                    contentsOf: extentDiagnostics(
                        size: size,
                        subject: subject,
                        allowZeroOn: nil,
                        labels: ["primitive.width": width, "primitive.height": height, "primitive.depth": depth]
                    )
                )
                shape = size.components.allSatisfy { $0 > 0 } ? .box(size: size) : nil
            } else {
                shape = nil
            }

        case .cylinder(let spec):
            let radius = scalar(spec.radius, field: "primitive.radius")
            let length = scalar(spec.length, field: "primitive.length")
            if let radius, let length {
                if radius <= 0 {
                    diagnostics.append(
                        .error(subject, field: "primitive.radius", "Radius must be greater than zero (got \(Expression.literalSource(radius))).")
                    )
                }
                if length <= 0 {
                    diagnostics.append(
                        .error(subject, field: "primitive.length", "Length must be greater than zero (got \(Expression.literalSource(length))).")
                    )
                }
                shape = radius > 0 && length > 0
                    ? .cylinder(radius: radius, length: length, axis: spec.axis)
                    : nil
            } else {
                shape = nil
            }

        case .sheet(let spec):
            let width = scalar(spec.width, field: "primitive.width")
            let depth = scalar(spec.depth, field: "primitive.depth")
            let thickness = scalar(spec.thickness, field: "primitive.thickness")
            if let width, let depth, let thickness {
                let (firstAxis, secondAxis) = spec.normal.perpendicular
                var size = Vec3.zero
                size[firstAxis] = width
                size[secondAxis] = depth
                size[spec.normal] = thickness

                if width <= 0 {
                    diagnostics.append(
                        .error(subject, field: "primitive.width", "Width must be greater than zero.")
                    )
                }
                if depth <= 0 {
                    diagnostics.append(
                        .error(subject, field: "primitive.depth", "Depth must be greater than zero.")
                    )
                }
                // Zero thickness is legal here: an infinitely thin PEC sheet is a
                // standard FDTD construct. Only negative values are rejected.
                if thickness < 0 {
                    diagnostics.append(
                        .error(subject, field: "primitive.thickness", "Thickness cannot be negative.")
                    )
                }
                shape = width > 0 && depth > 0 && thickness >= 0
                    ? .sheet(size: size, normal: spec.normal)
                    : nil
            } else {
                shape = nil
            }
        }

        let position = vector(body.transform.position, field: "transform.position")
        let rotation = vector(body.transform.rotationDegrees, field: "transform.rotation")
        let scale = vector(body.transform.scale, field: "transform.scale")

        if let scale, scale.components.contains(where: { $0 == 0 }) {
            diagnostics.append(
                .error(subject, field: "transform.scale", "Scale components cannot be zero.")
            )
        }

        guard
            let shape,
            let position,
            let rotation,
            let scale,
            !scale.components.contains(where: { $0 == 0 })
        else {
            return BodyOutcome(body: nil, diagnostics: diagnostics)
        }

        if shape.kind == .sheet, let degenerate = shape.degenerateAxis {
            diagnostics.append(
                .warning(
                    subject,
                    field: "primitive.thickness",
                    "Zero-thickness sheet: it will be meshed as a surface on the \(degenerate.displayName)-normal plane."
                )
            )
        }

        let resolved = ResolvedBody(
            id: body.id,
            name: body.name,
            shape: shape,
            position: position,
            rotationDegrees: rotation,
            scale: scale,
            materialID: body.effectiveMaterialID,
            priority: body.priority,
            isVisible: body.isVisible,
            orderIndex: orderIndex
        )
        return BodyOutcome(body: resolved, diagnostics: diagnostics)
    }

    private static func extentDiagnostics(
        size: Vec3,
        subject: Diagnostic.Subject,
        allowZeroOn: Axis?,
        labels: [String: Double]
    ) -> [Diagnostic] {
        labels.sorted { $0.key < $1.key }.compactMap { field, value in
            guard value <= 0 else { return nil }
            return .error(
                subject,
                field: field,
                "Extent must be greater than zero (got \(Expression.literalSource(value)))."
            )
        }
    }

    private static func nameCollisionDiagnostics(_ bodies: [CADBody]) -> [Diagnostic] {
        var seen: [String: UUID] = [:]
        var result: [Diagnostic] = []
        for body in bodies {
            let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                result.append(.warning(.body(body.id), field: "name", "Body has no name."))
                continue
            }
            if seen[name] != nil {
                result.append(
                    .warning(
                        .body(body.id),
                        field: "name",
                        "Another body is also called “\(name)”. Names are used in solver output, so keep them distinct."
                    )
                )
            } else {
                seen[name] = body.id
            }
        }
        return result
    }

    /// Overlapping bodies at equal priority are ambiguous for a voxeliser, so
    /// say so rather than letting array order silently decide.
    private static func priorityDiagnostics(bodies: [ResolvedBody]) -> [Diagnostic] {
        var result: [Diagnostic] = []
        let candidates = bodies.filter(\.isVisible)
        guard candidates.count > 1 else { return result }

        for (index, body) in candidates.enumerated() {
            for other in candidates[(index + 1)...] {
                guard body.priority == other.priority else { continue }
                guard body.materialID != other.materialID else { continue }
                guard body.axisAlignedBounds.intersects(other.axisAlignedBounds) else { continue }
                result.append(
                    .warning(
                        .body(other.id),
                        field: "priority",
                        "Overlaps “\(body.name)” at the same priority (\(body.priority)) with a different material. Set distinct priorities to make the overlap deterministic."
                    )
                )
            }
        }
        return result
    }

    // MARK: - Simulation

    private struct SimulationOutcome {
        var simulation: ResolvedSimulation
        var diagnostics: [Diagnostic]
    }

    private static func resolveSimulation(
        _ setup: SimulationSetup,
        variables: [String: Double],
        modelBounds: BodyBounds?,
        materials: [MaterialDefinition],
        lengthUnit: LengthUnit
    ) -> SimulationOutcome {
        var diagnostics: [Diagnostic] = []
        let subject = Diagnostic.Subject.simulation

        func scalar(_ expression: Expression, field: String, on subject: Diagnostic.Subject) -> Double? {
            do {
                return try expression.value(variables: variables)
            } catch {
                let message = (error as? ExpressionError)?.description ?? "Invalid expression."
                diagnostics.append(.error(subject, field: field, message))
                return nil
            }
        }

        // Frequency range
        if !setup.frequency.isValid {
            diagnostics.append(
                .error(
                    subject,
                    field: "frequency",
                    "Frequency range must be positive and increasing."
                )
            )
        }

        // Domain
        var domain: BodyBounds?
        switch setup.domain.mode {
        case .automatic:
            if let modelBounds {
                let paddingX = scalar(setup.domain.padding.x, field: "domain.padding.x", on: subject)
                let paddingY = scalar(setup.domain.padding.y, field: "domain.padding.y", on: subject)
                let paddingZ = scalar(setup.domain.padding.z, field: "domain.padding.z", on: subject)
                if let paddingX, let paddingY, let paddingZ {
                    if paddingX < 0 || paddingY < 0 || paddingZ < 0 {
                        diagnostics.append(
                            .error(subject, field: "domain.padding", "Padding cannot be negative.")
                        )
                    } else {
                        domain = modelBounds.expanded(
                            by: Vec3(x: paddingX, y: paddingY, z: paddingZ)
                        )
                    }
                }
            } else {
                diagnostics.append(
                    .warning(
                        subject,
                        field: "domain",
                        "Automatic domain needs at least one visible body."
                    )
                )
            }

        case .manual:
            do {
                let bounds = try setup.domain.manualBounds.value(variables: variables)
                if bounds.isInverted {
                    diagnostics.append(
                        .error(subject, field: "domain.manualBounds", "Domain minimum exceeds its maximum.")
                    )
                } else if bounds.size.components.contains(where: { $0 <= 0 }) {
                    diagnostics.append(
                        .error(subject, field: "domain.manualBounds", "Domain must have a positive extent on every axis.")
                    )
                } else {
                    domain = bounds
                }
            } catch {
                let message = (error as? ExpressionError)?.description ?? "Invalid expression."
                diagnostics.append(.error(subject, field: "domain.manualBounds", message))
            }
        }

        if let domain, let modelBounds, !domain.contains(modelBounds) {
            diagnostics.append(
                .warning(
                    subject,
                    field: "domain",
                    "The model extends outside the computational domain; geometry will be clipped."
                )
            )
        }

        // Boundaries
        for axis in setup.boundaries.mismatchedPeriodicAxes {
            diagnostics.append(
                .error(
                    subject,
                    field: "boundaries.\(axis.rawValue)",
                    "Periodic boundaries must be set on both \(axis.displayName) faces."
                )
            )
        }
        if setup.boundaries.pmlCellCount < 4 {
            diagnostics.append(
                .warning(
                    subject,
                    field: "boundaries.pmlCellCount",
                    "Fewer than 4 PML cells usually reflects noticeably."
                )
            )
        }

        // Mesh
        let meshOutcome = resolveMesh(
            setup: setup,
            variables: variables,
            materials: materials,
            lengthUnit: lengthUnit,
            domain: domain
        )
        diagnostics.append(contentsOf: meshOutcome.diagnostics)

        // Ports
        var ports: [ResolvedPort] = []
        var excitedPortCount = 0
        for port in setup.ports {
            let portSubject = Diagnostic.Subject.port(port.id)
            let bounds: BodyBounds
            do {
                bounds = try port.region.value(variables: variables)
            } catch {
                let message = (error as? ExpressionError)?.description ?? "Invalid expression."
                diagnostics.append(.error(portSubject, field: "region", message))
                continue
            }

            if bounds.isInverted {
                diagnostics.append(
                    .error(portSubject, field: "region", "Port minimum exceeds its maximum.")
                )
                continue
            }

            let gap = bounds.span(on: port.direction)
            if gap <= 0 {
                diagnostics.append(
                    .error(
                        portSubject,
                        field: "region",
                        "A \(port.kind.displayName.lowercased()) needs a non-zero span along \(port.direction.displayName), which is its \(port.kind == .lumped ? "gap" : "propagation") direction."
                    )
                )
                continue
            }

            if port.impedanceOhm <= 0 {
                diagnostics.append(
                    .error(portSubject, field: "impedanceOhm", "Reference impedance must be positive.")
                )
            }

            if let domain, !domain.contains(bounds) {
                diagnostics.append(
                    .warning(portSubject, field: "region", "Port lies partly outside the computational domain.")
                )
            }

            if port.kind == .waveguide {
                let (first, second) = port.direction.perpendicular
                if bounds.span(on: first) <= 0 || bounds.span(on: second) <= 0 {
                    diagnostics.append(
                        .error(
                            portSubject,
                            field: "region",
                            "A waveguide port needs a non-zero cross-section perpendicular to \(port.direction.displayName)."
                        )
                    )
                    continue
                }
            }

            if port.isExcited { excitedPortCount += 1 }

            ports.append(
                ResolvedPort(
                    id: port.id,
                    name: port.name,
                    kind: port.kind,
                    bounds: bounds,
                    direction: port.direction,
                    isReversed: port.isReversed,
                    impedanceOhm: port.impedanceOhm,
                    isExcited: port.isExcited,
                    amplitude: port.amplitude,
                    phaseDegrees: port.phaseDegrees,
                    modeIndex: port.modeIndex
                )
            )
        }

        if setup.ports.isEmpty {
            diagnostics.append(
                .warning(subject, field: "ports", "No ports defined; the run has nothing to excite and no S-parameters to report.")
            )
        } else if excitedPortCount == 0 {
            diagnostics.append(
                .warning(subject, field: "ports", "No port is set to excite the simulation.")
            )
        }

        // Monitors
        var monitors: [ResolvedMonitor] = []
        for monitor in setup.monitors where monitor.isEnabled {
            let monitorSubject = Diagnostic.Subject.monitor(monitor.id)
            var bounds: BodyBounds?
            var planeAxis: Axis?
            var planePosition: Double?

            switch monitor.region {
            case .wholeDomain:
                bounds = domain
            case .box(let region):
                do {
                    let value = try region.value(variables: variables)
                    if value.isInverted {
                        diagnostics.append(
                            .error(monitorSubject, field: "region", "Monitor minimum exceeds its maximum.")
                        )
                        continue
                    }
                    bounds = value
                } catch {
                    let message = (error as? ExpressionError)?.description ?? "Invalid expression."
                    diagnostics.append(.error(monitorSubject, field: "region", message))
                    continue
                }
            case .plane(let axis, let position):
                guard let value = scalar(position, field: "region.position", on: monitorSubject) else {
                    continue
                }
                planeAxis = axis
                planePosition = value
                bounds = domain
            }

            if monitor.quantity.requiresWholeDomain, case .wholeDomain = monitor.region {
                // Fine.
            } else if monitor.quantity.requiresWholeDomain {
                diagnostics.append(
                    .warning(
                        monitorSubject,
                        field: "region",
                        "\(monitor.quantity.displayName) results are only meaningful over the whole domain."
                    )
                )
            }

            for frequency in monitor.frequenciesHertz where frequency <= 0 {
                diagnostics.append(
                    .error(monitorSubject, field: "frequenciesHertz", "Monitor frequencies must be positive.")
                )
            }

            if setup.frequency.isValid {
                for frequency in monitor.frequenciesHertz
                where frequency < setup.frequency.minimumHertz || frequency > setup.frequency.maximumHertz {
                    diagnostics.append(
                        .warning(
                            monitorSubject,
                            field: "frequenciesHertz",
                            "\(FrequencyFormatter.string(hertz: frequency)) is outside the excited band \(setup.frequency.description); results there will be noise."
                        )
                    )
                }
            }

            monitors.append(
                ResolvedMonitor(
                    id: monitor.id,
                    name: monitor.name,
                    quantity: monitor.quantity,
                    bounds: bounds,
                    planeAxis: planeAxis,
                    planePosition: planePosition,
                    frequenciesHertz: monitor.frequenciesHertz
                )
            )
        }

        // Excitation
        if setup.excitation.waveform == .sinusoidal, setup.excitation.sinusoidalHertz <= 0 {
            diagnostics.append(
                .error(subject, field: "excitation.sinusoidalHertz", "Drive frequency must be positive.")
            )
        }
        if setup.solver.courantFactor <= 0 || setup.solver.courantFactor > 1 {
            diagnostics.append(
                .error(
                    subject,
                    field: "solver.courantFactor",
                    "Courant factor must be in (0, 1]; above 1 the update is unstable."
                )
            )
        }

        return SimulationOutcome(
            simulation: ResolvedSimulation(
                domain: domain,
                ports: ports,
                monitors: monitors,
                mesh: meshOutcome.plan
            ),
            diagnostics: diagnostics
        )
    }

    private struct MeshOutcome {
        var plan: ResolvedMeshPlan
        var diagnostics: [Diagnostic]
    }

    private static func resolveMesh(
        setup: SimulationSetup,
        variables: [String: Double],
        materials: [MaterialDefinition],
        lengthUnit: LengthUnit,
        domain: BodyBounds?
    ) -> MeshOutcome {
        var diagnostics: [Diagnostic] = []
        let subject = Diagnostic.Subject.simulation
        let mesh = setup.mesh

        if mesh.cellsPerWavelength < 6 {
            diagnostics.append(
                .warning(
                    subject,
                    field: "mesh.cellsPerWavelength",
                    "Below about 10 cells per wavelength, numerical dispersion dominates."
                )
            )
        }
        if mesh.maxGrowthRatio < 1 {
            diagnostics.append(
                .error(subject, field: "mesh.maxGrowthRatio", "Growth ratio must be at least 1.")
            )
        }

        // Wavelength criterion uses the highest frequency and the largest
        // refractive index present, since that is where the wavelength is
        // shortest.
        var wavelengthLimit: Double?
        if setup.frequency.isValid {
            let maximumIndex = materials
                .filter { $0.kind == .dielectric }
                .map { max(1.0, ($0.epsilonR * $0.muR).squareRoot()) }
                .max() ?? 1.0
            if let wavelength = lengthUnit.wavelength(atHertz: setup.frequency.maximumHertz) {
                wavelengthLimit = wavelength / maximumIndex / mesh.cellsPerWavelength
            }
        }

        var maxCellSize: Double?
        do {
            if let explicit = try mesh.maxCellSize.optionalValue(variables: variables) {
                if explicit <= 0 {
                    diagnostics.append(
                        .error(subject, field: "mesh.maxCellSize", "Maximum cell size must be positive.")
                    )
                } else {
                    maxCellSize = explicit
                }
            }
        } catch {
            let message = (error as? ExpressionError)?.description ?? "Invalid expression."
            diagnostics.append(.error(subject, field: "mesh.maxCellSize", message))
        }

        var minCellSize: Double?
        do {
            if let explicit = try mesh.minCellSize.optionalValue(variables: variables) {
                if explicit <= 0 {
                    diagnostics.append(
                        .error(subject, field: "mesh.minCellSize", "Minimum cell size must be positive.")
                    )
                } else {
                    minCellSize = explicit
                }
            }
        } catch {
            let message = (error as? ExpressionError)?.description ?? "Invalid expression."
            diagnostics.append(.error(subject, field: "mesh.minCellSize", message))
        }

        let effectiveMax: Double? = {
            switch (wavelengthLimit, maxCellSize) {
            case (let limit?, let explicit?): return min(limit, explicit)
            case (let limit?, nil): return limit
            case (nil, let explicit?): return explicit
            case (nil, nil): return nil
            }
        }()

        if let minCellSize, let effectiveMax, minCellSize > effectiveMax {
            diagnostics.append(
                .error(
                    subject,
                    field: "mesh.minCellSize",
                    "Minimum cell size exceeds the maximum implied by the wavelength criterion."
                )
            )
        }

        func lines(on axis: Axis) -> [Double] {
            var values: [Double] = []
            for (index, expression) in mesh.fixedLines(on: axis).enumerated() {
                guard !expression.isEmpty else { continue }
                do {
                    values.append(try expression.value(variables: variables))
                } catch {
                    let message = (error as? ExpressionError)?.description ?? "Invalid expression."
                    diagnostics.append(
                        .error(subject, field: "mesh.fixedLines.\(axis.rawValue)[\(index)]", message)
                    )
                }
            }
            return values.sorted()
        }

        var refinements: [ResolvedMeshRefinement] = []
        for refinement in mesh.refinements where refinement.isEnabled {
            do {
                let bounds = try refinement.region.value(variables: variables)
                guard let target = try refinement.targetCellSize.optionalValue(variables: variables) else {
                    diagnostics.append(
                        .error(subject, field: "mesh.refinement", "“\(refinement.name)” has no target cell size.")
                    )
                    continue
                }
                if target <= 0 {
                    diagnostics.append(
                        .error(subject, field: "mesh.refinement", "“\(refinement.name)” target cell size must be positive.")
                    )
                    continue
                }
                if bounds.isInverted {
                    diagnostics.append(
                        .error(subject, field: "mesh.refinement", "“\(refinement.name)” minimum exceeds its maximum.")
                    )
                    continue
                }
                refinements.append(
                    ResolvedMeshRefinement(
                        id: refinement.id,
                        name: refinement.name,
                        bounds: bounds,
                        targetCellSize: target
                    )
                )
            } catch {
                let message = (error as? ExpressionError)?.description ?? "Invalid expression."
                diagnostics.append(.error(subject, field: "mesh.refinement", message))
            }
        }

        let plan = ResolvedMeshPlan(
            wavelengthLimitedCellSize: wavelengthLimit,
            effectiveMaxCellSize: effectiveMax,
            minCellSize: minCellSize,
            fixedLinesX: lines(on: .x),
            fixedLinesY: lines(on: .y),
            fixedLinesZ: lines(on: .z),
            refinements: refinements
        )

        if let count = plan.estimatedCellCount(domain: domain), count > 50_000_000 {
            diagnostics.append(
                .warning(
                    subject,
                    field: "mesh",
                    "The uniform-fill cell estimate is about \(count / 1_000_000) million; consider a coarser base mesh with local refinement."
                )
            )
        }

        return MeshOutcome(plan: plan, diagnostics: diagnostics)
    }
}
