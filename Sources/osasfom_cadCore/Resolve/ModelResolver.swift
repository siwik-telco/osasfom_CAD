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
            // Only materials a visible body actually uses. Scanning the whole
            // library instead meant an unused FR-4 (εr 4.3) in the default set
            // silently halved the cell size of an all-air model, costing 8x
            // the cells and 2x the timesteps for nothing.
            materials: {
                let inUse = Set(bodies.filter(\.isVisible).map(\.materialID))
                return state.materials.filter { inUse.contains($0.id) }
            }(),
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

    /// A primitive plus its transform, both evaluated.
    ///
    /// Shared by a body's own shape and by each of its boolean tools, so a
    /// tool is placed by exactly the same rules a body is — including the
    /// begin/end overrides that make a box's, a cylinder's and a sheet's
    /// coordinates absolute rather than centred on Position.
    private struct PlacedShape {
        var shape: ResolvedShape
        var position: Vec3
        var rotationDegrees: Vec3
        var scale: Vec3
    }

    private static func resolvePlacement(
        primitive: Primitive,
        transform: BodyTransform,
        variables: [String: Double],
        subject: Diagnostic.Subject,
        fieldPrefix: String,
        diagnostics: inout [Diagnostic]
    ) -> PlacedShape? {
        func scalar(_ expression: Expression, field: String) -> Double? {
            do {
                return try expression.value(variables: variables)
            } catch {
                let message = (error as? ExpressionError)?.description ?? "Invalid expression."
                diagnostics.append(.error(subject, field: fieldPrefix + field, message))
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

        func error(_ field: String, _ message: String) {
            diagnostics.append(.error(subject, field: fieldPrefix + field, message))
        }

        let shape: ResolvedShape?
        /// A box's begin/end are absolute on every axis, so (unlike every
        /// other primitive) its resolved position doesn't come from
        /// transform.position at all — this carries the override out of the
        /// switch to where `position` is assembled below.
        var boxCenterOverride: Vec3?
        /// A sheet's begin/end are absolute only along its normal axis; the
        /// other two still take their center from transform.position.
        var sheetNormalOverride: (axis: Axis, center: Double)?

        switch primitive {
        case .box(let spec):
            var boxBegin = Vec3.zero
            var boxEnd = Vec3.zero
            var allResolved = true
            for axis in Axis.allCases {
                guard
                    let beginValue = scalar(spec.begin(axis), field: "primitive.begin\(axis.displayName)"),
                    let endValue = scalar(spec.end(axis), field: "primitive.end\(axis.displayName)")
                else {
                    allResolved = false
                    continue
                }
                boxBegin[axis] = beginValue
                boxEnd[axis] = endValue
                if beginValue == endValue {
                    error(
                        "primitive.end\(axis.displayName)",
                        "Begin and end must differ along \(axis.displayName); a zero-extent box has no volume."
                    )
                }
            }
            if allResolved {
                let size = Vec3(
                    x: abs(boxEnd.x - boxBegin.x),
                    y: abs(boxEnd.y - boxBegin.y),
                    z: abs(boxEnd.z - boxBegin.z)
                )
                let isValid = size.components.allSatisfy { $0 > 0 }
                shape = isValid ? .box(size: size) : nil
                boxCenterOverride = isValid
                    ? Vec3(x: (boxBegin.x + boxEnd.x) / 2, y: (boxBegin.y + boxEnd.y) / 2, z: (boxBegin.z + boxEnd.z) / 2)
                    : nil
            } else {
                shape = nil
            }

        case .cylinder(let spec):
            let radius = scalar(spec.radius, field: "primitive.radius")
            let begin = scalar(spec.begin, field: "primitive.begin")
            let end = scalar(spec.end, field: "primitive.end")
            if let radius, let begin, let end {
                if radius <= 0 {
                    error("primitive.radius", "Radius must be greater than zero (got \(Expression.literalSource(radius))).")
                }
                if begin == end {
                    error("primitive.end", "Begin and end must differ along \(spec.axis.displayName); a zero-length cylinder has no volume.")
                }
                shape = radius > 0 && begin != end
                    ? .cylinder(radius: radius, begin: begin, end: end, axis: spec.axis)
                    : nil
            } else {
                shape = nil
            }

        case .sheet(let spec):
            let width = scalar(spec.width, field: "primitive.width")
            let depth = scalar(spec.depth, field: "primitive.depth")
            let normalBegin = scalar(spec.begin, field: "primitive.begin")
            let normalEnd = scalar(spec.end, field: "primitive.end")
            if let width, let depth, let normalBegin, let normalEnd {
                let thickness = abs(normalEnd - normalBegin)
                let (firstAxis, secondAxis) = spec.normal.perpendicular
                var size = Vec3.zero
                size[firstAxis] = width
                size[secondAxis] = depth
                size[spec.normal] = thickness

                if width <= 0 {
                    error("primitive.width", "Width must be greater than zero.")
                }
                if depth <= 0 {
                    error("primitive.depth", "Depth must be greater than zero.")
                }
                // begin == end is legal here: an infinitely thin PEC sheet is a
                // standard FDTD construct.
                shape = width > 0 && depth > 0
                    ? .sheet(size: size, normal: spec.normal)
                    : nil
                if shape != nil {
                    sheetNormalOverride = (axis: spec.normal, center: (normalBegin + normalEnd) / 2)
                }
            } else {
                shape = nil
            }

        case .mesh(let spec):
            // Nothing to evaluate: the triangles are the geometry, already
            // centred on the body's origin by `STLImporter`, so the body's
            // position places them exactly like a box's centre would. The
            // mesh rides through by reference — re-resolving on every edit
            // must not rebuild its BVH.
            shape = .mesh(spec.mesh)
        }

        var position = vector(transform.position, field: "transform.position")
        let rotation = vector(transform.rotationDegrees, field: "transform.rotation")
        let scale = vector(transform.scale, field: "transform.scale")

        // A cylinder's begin/end are absolute coordinates along its axis, not
        // an extent centred on the body's position — so its resolved position
        // on that one axis comes from the midpoint of begin/end instead of
        // from transform.position. The other two axes still take their center
        // from transform.position, same as every other primitive.
        if case let .cylinder(_, begin, end, axis)? = shape {
            position?[axis] = (begin + end) / 2
        }
        // A box's begin/end are absolute on every axis, so transform.position
        // is unused for a box entirely.
        if let boxCenterOverride {
            position = boxCenterOverride
        }
        // A sheet's begin/end are absolute only along its normal axis.
        if let sheetNormalOverride {
            position?[sheetNormalOverride.axis] = sheetNormalOverride.center
        }

        if let scale, scale.components.contains(where: { $0 == 0 }) {
            error("transform.scale", "Scale components cannot be zero.")
        }

        guard
            let shape,
            let position,
            let rotation,
            let scale,
            !scale.components.contains(where: { $0 == 0 })
        else {
            return nil
        }

        return PlacedShape(shape: shape, position: position, rotationDegrees: rotation, scale: scale)
    }

    private static func resolveBody(
        _ body: CADBody,
        orderIndex: Int,
        variables: [String: Double]
    ) -> BodyOutcome {
        var diagnostics: [Diagnostic] = []
        let subject = Diagnostic.Subject.body(body.id)

        let base = resolvePlacement(
            primitive: body.primitive,
            transform: body.transform,
            variables: variables,
            subject: subject,
            fieldPrefix: "",
            diagnostics: &diagnostics
        )

        // Disabled steps are dropped here rather than carried into the
        // resolved model, so everything downstream can take the list at face
        // value. Their expressions are still resolved, so a typo in a
        // switched-off step is still reported instead of lying in wait.
        var booleans: [ResolvedBooleanOperation] = []
        for (index, step) in body.booleans.enumerated() {
            let placed = resolvePlacement(
                primitive: step.primitive,
                transform: step.transform,
                variables: variables,
                subject: subject,
                fieldPrefix: "booleans[\(index)].",
                diagnostics: &diagnostics
            )
            guard step.isEnabled, let placed else { continue }
            booleans.append(
                ResolvedBooleanOperation(
                    id: step.id,
                    kind: step.kind,
                    shape: placed.shape,
                    position: placed.position,
                    rotationDegrees: placed.rotationDegrees,
                    scale: placed.scale
                )
            )
        }

        guard let base else {
            return BodyOutcome(body: nil, diagnostics: diagnostics)
        }

        if base.shape.kind == .sheet, let degenerate = base.shape.degenerateAxis {
            diagnostics.append(
                .warning(
                    subject,
                    field: "primitive.thickness",
                    "Zero-thickness sheet: it will be meshed as a surface on the \(degenerate.displayName)-normal plane."
                )
            )
            if !booleans.isEmpty {
                diagnostics.append(
                    .warning(
                        subject,
                        field: "booleans",
                        "A zero-thickness sheet has no volume to cut, so the viewport and STL export draw it whole. The solver still applies these steps to the surface itself."
                    )
                )
            }
        }

        let resolved = ResolvedBody(
            id: body.id,
            name: body.name,
            shape: base.shape,
            position: base.position,
            rotationDegrees: base.rotationDegrees,
            scale: base.scale,
            materialID: body.effectiveMaterialID,
            priority: body.priority,
            isVisible: body.isVisible,
            orderIndex: orderIndex,
            booleans: booleans
        )
        return BodyOutcome(body: resolved, diagnostics: diagnostics)
    }

    private static func extentDiagnostics(
        subject: Diagnostic.Subject,
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

    /// The cell size the wavelength criterion allows, before any explicit
    /// `maxCellSize` narrows it further.
    ///
    /// Shared by the mesh plan and by the frequency-driven domain, which needs
    /// it to express its clearance requirement in cells.
    static func wavelengthLimitedCellSize(
        setup: SimulationSetup,
        materials: [MaterialDefinition],
        lengthUnit: LengthUnit
    ) -> Double? {
        guard setup.frequency.isValid else { return nil }
        // The shortest wavelength in the model sets the cell size: highest
        // frequency, densest material.
        let maximumIndex = materials
            .filter { $0.kind == .dielectric }
            .map { max(1.0, ($0.epsilonR * $0.muR).squareRoot()) }
            .max() ?? 1.0
        guard let wavelength = lengthUnit.wavelength(atHertz: setup.frequency.maximumHertz) else {
            return nil
        }
        return wavelength / maximumIndex / setup.mesh.cellsPerWavelength
    }

    /// Padding for `.fromFrequency`, in project units.
    ///
    /// Sized on the *longest* wavelength in the sweep — the lowest frequency —
    /// because that is the field that takes longest to decay before reaching
    /// the absorbing boundary. Sizing on the highest frequency would look
    /// tighter and be wrong.
    private static func frequencyDerivedPadding(
        setup: SimulationSetup,
        materials: [MaterialDefinition],
        lengthUnit: LengthUnit,
        diagnostics: inout [Diagnostic],
        subject: Diagnostic.Subject
    ) -> Double? {
        guard setup.frequency.isValid else {
            diagnostics.append(
                .error(
                    subject,
                    field: "domain.mode",
                    "The domain is sized from the frequency range, so a valid range is required. Set one, or switch the domain to manual bounds."
                )
            )
            return nil
        }
        guard let longestWavelength = lengthUnit.wavelength(atHertz: setup.frequency.minimumHertz) else {
            return nil
        }

        let factor = max(setup.domain.paddingWavelengths, 0.05)
        var padding = factor * longestWavelength

        // A far-field surface has to sit outside the absorber and still
        // enclose the antenna. If the wavelength rule alone would not leave
        // room, widen until it does — an automatic domain that silently
        // cannot produce the pattern that was asked for is not automatic.
        if setup.farField.isEnabled,
           let cellSize = wavelengthLimitedCellSize(setup: setup, materials: materials, lengthUnit: lengthUnit),
           cellSize > 0 {
            let requiredCellsPerSide = Double(setup.boundaries.pmlCellCount) + 2 + 4
            let minimumPadding = requiredCellsPerSide * cellSize
            if minimumPadding > padding {
                padding = minimumPadding
                diagnostics.append(
                    .warning(
                        subject,
                        field: "domain.paddingWavelengths",
                        "Padding widened to \(Expression.literalSource(padding)) so the far-field surface fits outside the \(setup.boundaries.pmlCellCount)-cell absorbing boundary. Raise the padding, or lower the PML cell count, to control this yourself."
                    )
                )
            }
        }
        return padding
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
        case .fromFrequency:
            if let modelBounds {
                if let padding = frequencyDerivedPadding(
                    setup: setup,
                    materials: materials,
                    lengthUnit: lengthUnit,
                    diagnostics: &diagnostics,
                    subject: subject
                ) {
                    domain = modelBounds.expanded(by: Vec3(repeating: padding))
                }
            } else {
                diagnostics.append(
                    .warning(
                        subject,
                        field: "domain",
                        "No visible bodies, so there is nothing to size the domain around."
                    )
                )
            }

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
        // A matched periodic pair passes validation, so say what the solver
        // actually does with it rather than let it look implemented.
        for axis in Axis.allCases
        where setup.boundaries.lower(on: axis) == .periodic && setup.boundaries.upper(on: axis) == .periodic {
            diagnostics.append(
                .warning(
                    subject,
                    field: "boundaries.\(axis.rawValue)",
                    "Periodic boundaries are not implemented yet; both \(axis.displayName) faces are simulated as electric walls."
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
            if let resolved = resolvePort(
                port,
                variables: variables,
                domain: domain,
                diagnostics: &diagnostics,
                subject: portSubject
            ) {
                if resolved.isExcited { excitedPortCount += 1 }
                ports.append(resolved)
            }
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

    private static func resolvePort(
        _ port: SimulationPort,
        variables: [String: Double],
        domain: BodyBounds?,
        diagnostics: inout [Diagnostic],
        subject: Diagnostic.Subject
    ) -> ResolvedPort? {
        func expressionMessage(_ error: Error) -> String {
            (error as? ExpressionError)?.description ?? "Invalid expression."
        }

        if port.impedanceOhm <= 0 {
            diagnostics.append(
                .error(subject, field: "impedanceOhm", "Reference impedance must be positive.")
            )
        }

        switch port.kind {
        case .lumped:
            let begin: Vec3
            let end: Vec3
            do {
                begin = try port.begin.value(variables: variables)
            } catch {
                diagnostics.append(.error(subject, field: "begin", expressionMessage(error)))
                return nil
            }
            do {
                end = try port.end.value(variables: variables)
            } catch {
                diagnostics.append(.error(subject, field: "end", expressionMessage(error)))
                return nil
            }

            switch LumpedPortGeometry.from(begin: begin, end: end) {
            case .failure(.coincidentTerminals):
                diagnostics.append(
                    .error(
                        subject,
                        field: "end",
                        "A lumped port needs distinct begin and end terminals; the gap is the feed the solver stamps onto Yee edges."
                    )
                )
                return nil
            case .failure(.notAxisAligned):
                diagnostics.append(
                    .error(
                        subject,
                        field: "end",
                        "A lumped port must be axis-aligned (the two terminals may differ on only one of X, Y or Z) so the feed lies on Yee edges."
                    )
                )
                return nil
            case .success(let geometry):
                if let domain, !domain.contains(begin) || !domain.contains(end) {
                    diagnostics.append(
                        .warning(
                            subject,
                            field: "begin",
                            "Lumped-port terminals lie partly outside the computational domain."
                        )
                    )
                }
                return ResolvedPort(
                    id: port.id,
                    name: port.name,
                    kind: .lumped,
                    begin: geometry.begin,
                    end: geometry.end,
                    bounds: geometry.bounds,
                    direction: geometry.direction,
                    isReversed: geometry.polarityFlipped,
                    impedanceOhm: port.impedanceOhm,
                    isExcited: port.isExcited,
                    amplitude: port.amplitude,
                    phaseDegrees: port.phaseDegrees,
                    modeIndex: port.modeIndex,
                    gapLength: geometry.gapLength
                )
            }

        case .waveguide:
            let bounds: BodyBounds
            do {
                bounds = try port.region.value(variables: variables)
            } catch {
                diagnostics.append(.error(subject, field: "region", expressionMessage(error)))
                return nil
            }

            if bounds.isInverted {
                diagnostics.append(
                    .error(subject, field: "region", "SimulationPort minimum exceeds its maximum.")
                )
                return nil
            }

            let gap = bounds.span(on: port.direction)
            if gap <= 0 {
                diagnostics.append(
                    .error(
                        subject,
                        field: "region",
                        "A waveguide port needs a non-zero span along \(port.direction.displayName), which is its propagation direction."
                    )
                )
                return nil
            }

            let (first, second) = port.direction.perpendicular
            if bounds.span(on: first) <= 0 || bounds.span(on: second) <= 0 {
                diagnostics.append(
                    .error(
                        subject,
                        field: "region",
                        "A waveguide port needs a non-zero cross-section perpendicular to \(port.direction.displayName)."
                    )
                )
                return nil
            }

            if let domain, !domain.contains(bounds) {
                diagnostics.append(
                    .warning(subject, field: "region", "SimulationPort lies partly outside the computational domain.")
                )
            }

            return ResolvedPort(
                id: port.id,
                name: port.name,
                kind: .waveguide,
                bounds: bounds,
                direction: port.direction,
                isReversed: port.isReversed,
                impedanceOhm: port.impedanceOhm,
                isExcited: port.isExcited,
                amplitude: port.amplitude,
                phaseDegrees: port.phaseDegrees,
                modeIndex: port.modeIndex,
                gapLength: gap
            )
        }
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
        let wavelengthLimit = wavelengthLimitedCellSize(
            setup: setup,
            materials: materials,
            lengthUnit: lengthUnit
        )

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
