import Foundation

/// The solver-facing contract.
///
/// Three rules make this usable as an interface rather than a data dump:
/// 1. **Everything is SI.** Lengths in metres, frequencies in hertz, σ in S/m.
///    The project's display unit is recorded for provenance only.
/// 2. **Everything is resolved.** No expressions, no variable references. The
///    variable table is included for traceability but nothing depends on it.
/// 3. **Overlap is deterministic.** `bodies` is emitted in material-assignment
///    order — highest priority first — and a voxeliser applies the first body
///    that claims a cell.
///
/// A body that failed to resolve is never exported; `export` refuses to run
/// while the model has errors, so a partial file cannot masquerade as complete.
public struct SolverExport: Encodable, Sendable {
    public static let schemaVersion = 1

    public struct Meta: Encodable, Sendable {
        public let schemaVersion: Int
        public let generator: String
        public let projectName: String
        public let displayLengthUnit: String
        public let metersPerDisplayUnit: Double
        public let coordinateSystem: String
        public let rotationConvention: String
        public let overlapRule: String
    }

    public struct VariableRecord: Encodable, Sendable {
        public let name: String
        public let expression: String
        public let value: Double
        public let comment: String
    }

    public struct DispersionRecord: Encodable, Sendable {
        public struct Pole: Encodable, Sendable {
            public let deltaEpsilon: Double
            public let relaxationTimeSeconds: Double?
            public let resonanceHertz: Double?
            public let dampingHertz: Double?
        }

        public let model: String
        public let poles: [Pole]?
        public let plasmaHertz: Double?
        public let collisionHertz: Double?
    }

    public struct MaterialRecord: Encodable, Sendable {
        public let id: String
        public let name: String
        public let kind: String
        public let epsilonR: Double?
        public let muR: Double?
        public let electricConductivitySiemensPerMeter: Double?
        public let magneticConductivityOhmPerMeter: Double?
        public let dispersion: DispersionRecord?
        public let reference: String
    }

    public struct BoxRecord: Encodable, Sendable {
        public let xMin: Double
        public let xMax: Double
        public let yMin: Double
        public let yMax: Double
        public let zMin: Double
        public let zMax: Double

        public init(_ bounds: BodyBounds, unit: LengthUnit) {
            let meters = unit.toMeters(bounds)
            xMin = meters.xMin
            xMax = meters.xMax
            yMin = meters.yMin
            yMax = meters.yMax
            zMin = meters.zMin
            zMax = meters.zMax
        }
    }

    public struct VectorRecord: Encodable, Sendable {
        public let x: Double
        public let y: Double
        public let z: Double

        public init(_ vector: Vec3) {
            x = vector.x
            y = vector.y
            z = vector.z
        }
    }

    public struct ShapeRecord: Encodable, Sendable {
        public let type: String
        /// Box and sheet: full extents in metres, before rotation.
        public let size: VectorRecord?
        public let radiusMeters: Double?
        public let lengthMeters: Double?
        public let axis: String?
        /// Sheets only. `true` means a zero-thickness surface.
        public let isZeroThickness: Bool?
    }

    public struct BodyRecord: Encodable, Sendable {
        public let id: String
        public let name: String
        /// Higher wins an overlap. Records are already sorted by this.
        public let priority: Int
        public let materialID: String
        public let shape: ShapeRecord
        public let positionMeters: VectorRecord
        public let rotationDegrees: VectorRecord
        public let scale: VectorRecord
        /// Precomputed so a mesher does not have to redo the rotated-corner
        /// transform to bracket the body's cells.
        public let axisAlignedBoundsMeters: BoxRecord
    }

    public struct BoundaryRecord: Encodable, Sendable {
        public let xMin: String
        public let xMax: String
        public let yMin: String
        public let yMax: String
        public let zMin: String
        public let zMax: String
        public let pmlCellCount: Int
    }

    public struct MeshRefinementRecord: Encodable, Sendable {
        public let id: String
        public let name: String
        public let regionMeters: BoxRecord
        public let targetCellSizeMeters: Double
    }

    public struct MeshRecord: Encodable, Sendable {
        public let cellsPerWavelength: Double
        public let wavelengthLimitedCellSizeMeters: Double?
        public let maxCellSizeMeters: Double?
        public let minCellSizeMeters: Double?
        public let maxGrowthRatio: Double
        public let snapToBodyEdges: Bool
        public let fixedLinesXMeters: [Double]
        public let fixedLinesYMeters: [Double]
        public let fixedLinesZMeters: [Double]
        public let refinements: [MeshRefinementRecord]
        public let estimatedUniformCellCount: Int?
    }

    public struct ExcitationRecord: Encodable, Sendable {
        public let waveform: String
        public let frequencyMinimumHertz: Double
        public let frequencyMaximumHertz: Double
        public let sinusoidalHertz: Double?
        public let stepRiseTimeSeconds: Double?
    }

    public struct PortRecord: Encodable, Sendable {
        public let id: String
        public let name: String
        public let kind: String
        public let regionMeters: BoxRecord
        public let direction: String
        public let isReversed: Bool
        public let impedanceOhm: Double
        public let isExcited: Bool
        public let amplitude: Double
        public let phaseDegrees: Double
        public let modeIndex: Int?
        public let gapLengthMeters: Double
    }

    public struct MonitorRecord: Encodable, Sendable {
        public let id: String
        public let name: String
        public let quantity: String
        public let regionType: String
        public let regionMeters: BoxRecord?
        public let planeAxis: String?
        public let planePositionMeters: Double?
        public let frequenciesHertz: [Double]
    }

    public struct SolverRecord: Encodable, Sendable {
        public let energyDecayDecibels: Double
        public let maximumTimeSteps: Int
        public let courantFactor: Double
    }

    public let meta: Meta
    public let variables: [VariableRecord]
    public let materials: [MaterialRecord]
    /// Sorted by descending priority; the first body claiming a cell wins.
    public let bodies: [BodyRecord]
    public let domainMeters: BoxRecord?
    public let boundaries: BoundaryRecord
    public let mesh: MeshRecord
    public let excitation: ExcitationRecord
    public let ports: [PortRecord]
    public let monitors: [MonitorRecord]
    public let solver: SolverRecord
    /// Non-blocking warnings that survived validation, so a batch run can log them.
    public let warnings: [String]
}

public enum SolverExportError: Error, LocalizedError {
    case modelHasErrors([Diagnostic])
    case noDomain

    public var errorDescription: String? {
        switch self {
        case .modelHasErrors(let diagnostics):
            let list = diagnostics.prefix(5).map { "• \($0.message)" }.joined(separator: "\n")
            let extra = diagnostics.count > 5 ? "\n… and \(diagnostics.count - 5) more." : ""
            return "The model has \(diagnostics.count) error(s) and cannot be exported:\n\(list)\(extra)"
        case .noDomain:
            return "The computational domain is undefined. Add at least one visible body, or switch the domain to manual bounds."
        }
    }
}

public enum SolverExportEncoder {
    /// Refuses to produce a file while the model has errors — a solver deck that
    /// silently omits a broken body is worse than no deck.
    public static func makeExport(state: CADModelState, resolved: ResolvedModel) throws -> SolverExport {
        let errors = resolved.diagnostics.errors
        guard errors.isEmpty else { throw SolverExportError.modelHasErrors(errors) }
        guard let domain = resolved.simulation.domain else { throw SolverExportError.noDomain }

        let unit = state.lengthUnit
        let setup = state.simulation

        let meta = SolverExport.Meta(
            schemaVersion: SolverExport.schemaVersion,
            generator: CADProjectFile.defaultGenerator,
            projectName: state.name,
            displayLengthUnit: unit.symbol,
            metersPerDisplayUnit: unit.metersPerUnit,
            coordinateSystem: "right-handed, Y up",
            rotationConvention: "extrinsic XYZ degrees, applied Z then Y then X",
            overlapRule: "bodies are listed in assignment order; the first body containing a cell owns it"
        )

        let variables = state.variables.compactMap { variable -> SolverExport.VariableRecord? in
            guard let value = resolved.variables.valuesByID[variable.id] else { return nil }
            return SolverExport.VariableRecord(
                name: variable.trimmedName,
                expression: variable.expression.trimmed,
                value: value,
                comment: variable.comment
            )
        }

        // Only materials actually in use, so the deck stays small.
        let usedMaterialIDs = Set(resolved.bodies.map(\.materialID))
        let materials = state.materials
            .filter { usedMaterialIDs.contains($0.id) }
            .map(materialRecord(for:))

        let orderedBodies = resolved.bodies
            .filter(\.isVisible)
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.orderIndex > rhs.orderIndex
            }

        let bodies = orderedBodies.map { body in
            SolverExport.BodyRecord(
                id: body.id.uuidString,
                name: body.name,
                priority: body.priority,
                materialID: body.materialID.uuidString,
                shape: shapeRecord(for: body.shape, unit: unit),
                positionMeters: SolverExport.VectorRecord(unit.toMeters(body.position)),
                rotationDegrees: SolverExport.VectorRecord(body.rotationDegrees),
                scale: SolverExport.VectorRecord(body.scale),
                axisAlignedBoundsMeters: SolverExport.BoxRecord(body.axisAlignedBounds, unit: unit)
            )
        }

        let plan = resolved.simulation.mesh
        let mesh = SolverExport.MeshRecord(
            cellsPerWavelength: setup.mesh.cellsPerWavelength,
            wavelengthLimitedCellSizeMeters: plan.wavelengthLimitedCellSize.map(unit.toMeters),
            maxCellSizeMeters: plan.effectiveMaxCellSize.map(unit.toMeters),
            minCellSizeMeters: plan.minCellSize.map(unit.toMeters),
            maxGrowthRatio: setup.mesh.maxGrowthRatio,
            snapToBodyEdges: setup.mesh.snapToBodyEdges,
            fixedLinesXMeters: plan.fixedLinesX.map(unit.toMeters),
            fixedLinesYMeters: plan.fixedLinesY.map(unit.toMeters),
            fixedLinesZMeters: plan.fixedLinesZ.map(unit.toMeters),
            refinements: plan.refinements.map { refinement in
                SolverExport.MeshRefinementRecord(
                    id: refinement.id.uuidString,
                    name: refinement.name,
                    regionMeters: SolverExport.BoxRecord(refinement.bounds, unit: unit),
                    targetCellSizeMeters: unit.toMeters(refinement.targetCellSize)
                )
            },
            estimatedUniformCellCount: plan.estimatedCellCount(domain: domain)
        )

        let excitation = SolverExport.ExcitationRecord(
            waveform: setup.excitation.waveform.rawValue,
            frequencyMinimumHertz: setup.frequency.minimumHertz,
            frequencyMaximumHertz: setup.frequency.maximumHertz,
            sinusoidalHertz: setup.excitation.waveform == .sinusoidal
                ? setup.excitation.sinusoidalHertz
                : nil,
            stepRiseTimeSeconds: setup.excitation.waveform == .step
                ? setup.excitation.stepRiseTimeSeconds
                : nil
        )

        let ports = resolved.simulation.ports.map { port in
            SolverExport.PortRecord(
                id: port.id.uuidString,
                name: port.name,
                kind: port.kind.rawValue,
                regionMeters: SolverExport.BoxRecord(port.bounds, unit: unit),
                direction: port.direction.rawValue,
                isReversed: port.isReversed,
                impedanceOhm: port.impedanceOhm,
                isExcited: port.isExcited,
                amplitude: port.amplitude,
                phaseDegrees: port.phaseDegrees,
                modeIndex: port.kind == .waveguide ? port.modeIndex : nil,
                gapLengthMeters: unit.toMeters(port.gapLength)
            )
        }

        let monitors = resolved.simulation.monitors.map { monitor -> SolverExport.MonitorRecord in
            let regionType: String
            if monitor.planeAxis != nil {
                regionType = "plane"
            } else if monitor.bounds != nil {
                regionType = "box"
            } else {
                regionType = "wholeDomain"
            }
            return SolverExport.MonitorRecord(
                id: monitor.id.uuidString,
                name: monitor.name,
                quantity: monitor.quantity.rawValue,
                regionType: regionType,
                regionMeters: monitor.bounds.map { SolverExport.BoxRecord($0, unit: unit) },
                planeAxis: monitor.planeAxis?.rawValue,
                planePositionMeters: monitor.planePosition.map(unit.toMeters),
                frequenciesHertz: monitor.frequenciesHertz
            )
        }

        return SolverExport(
            meta: meta,
            variables: variables,
            materials: materials,
            bodies: bodies,
            domainMeters: SolverExport.BoxRecord(domain, unit: unit),
            boundaries: SolverExport.BoundaryRecord(
                xMin: setup.boundaries.xMin.rawValue,
                xMax: setup.boundaries.xMax.rawValue,
                yMin: setup.boundaries.yMin.rawValue,
                yMax: setup.boundaries.yMax.rawValue,
                zMin: setup.boundaries.zMin.rawValue,
                zMax: setup.boundaries.zMax.rawValue,
                pmlCellCount: setup.boundaries.pmlCellCount
            ),
            mesh: mesh,
            excitation: excitation,
            ports: ports,
            monitors: monitors,
            solver: SolverExport.SolverRecord(
                energyDecayDecibels: setup.solver.energyDecayDecibels,
                maximumTimeSteps: setup.solver.maximumTimeSteps,
                courantFactor: setup.solver.courantFactor
            ),
            warnings: resolved.diagnostics.warnings.map(\.message)
        )
    }

    public static func encode(state: CADModelState, resolved: ResolvedModel) throws -> Data {
        let export = try makeExport(state: state, resolved: resolved)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(export)
    }

    // MARK: - Records

    private static func materialRecord(for material: MaterialDefinition) -> SolverExport.MaterialRecord {
        let usesParameters = material.kind.usesConstitutiveParameters
        return SolverExport.MaterialRecord(
            id: material.id.uuidString,
            name: material.name,
            kind: material.kind.rawValue,
            epsilonR: usesParameters ? material.epsilonR : nil,
            muR: usesParameters ? material.muR : nil,
            electricConductivitySiemensPerMeter: usesParameters ? material.electricConductivity : nil,
            magneticConductivityOhmPerMeter: usesParameters ? material.magneticConductivity : nil,
            dispersion: usesParameters ? dispersionRecord(for: material.dispersion) : nil,
            reference: material.reference
        )
    }

    private static func dispersionRecord(for model: DispersionModel) -> SolverExport.DispersionRecord? {
        switch model {
        case .none:
            return nil
        case .debye(let poles):
            return SolverExport.DispersionRecord(
                model: "debye",
                poles: poles.map { pole in
                    SolverExport.DispersionRecord.Pole(
                        deltaEpsilon: pole.deltaEpsilon,
                        relaxationTimeSeconds: pole.relaxationTimeSeconds,
                        resonanceHertz: nil,
                        dampingHertz: nil
                    )
                },
                plasmaHertz: nil,
                collisionHertz: nil
            )
        case .drude(let plasmaHertz, let collisionHertz):
            return SolverExport.DispersionRecord(
                model: "drude",
                poles: nil,
                plasmaHertz: plasmaHertz,
                collisionHertz: collisionHertz
            )
        case .lorentz(let poles):
            return SolverExport.DispersionRecord(
                model: "lorentz",
                poles: poles.map { pole in
                    SolverExport.DispersionRecord.Pole(
                        deltaEpsilon: pole.deltaEpsilon,
                        relaxationTimeSeconds: nil,
                        resonanceHertz: pole.resonanceHertz,
                        dampingHertz: pole.dampingHertz
                    )
                },
                plasmaHertz: nil,
                collisionHertz: nil
            )
        }
    }

    private static func shapeRecord(
        for shape: ResolvedShape,
        unit: LengthUnit
    ) -> SolverExport.ShapeRecord {
        switch shape {
        case .box(let size):
            return SolverExport.ShapeRecord(
                type: "box",
                size: SolverExport.VectorRecord(unit.toMeters(size)),
                radiusMeters: nil,
                lengthMeters: nil,
                axis: nil,
                isZeroThickness: nil
            )
        case .cylinder(let radius, let length, let axis):
            return SolverExport.ShapeRecord(
                type: "cylinder",
                size: nil,
                radiusMeters: unit.toMeters(radius),
                lengthMeters: unit.toMeters(length),
                axis: axis.rawValue,
                isZeroThickness: nil
            )
        case .sheet(let size, let normal):
            return SolverExport.ShapeRecord(
                type: "sheet",
                size: SolverExport.VectorRecord(unit.toMeters(size)),
                radiusMeters: nil,
                lengthMeters: nil,
                axis: normal.rawValue,
                isZeroThickness: size[normal] == 0
            )
        }
    }
}
