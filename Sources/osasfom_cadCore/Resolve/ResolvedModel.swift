import Foundation

public struct ResolvedPort: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: PortKind
    public let bounds: BodyBounds
    public let direction: Axis
    public let isReversed: Bool
    public let impedanceOhm: Double
    public let isExcited: Bool
    public let amplitude: Double
    public let phaseDegrees: Double
    public let modeIndex: Int

    public init(
        id: UUID,
        name: String,
        kind: PortKind,
        bounds: BodyBounds,
        direction: Axis,
        isReversed: Bool,
        impedanceOhm: Double,
        isExcited: Bool,
        amplitude: Double,
        phaseDegrees: Double,
        modeIndex: Int
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bounds = bounds
        self.direction = direction
        self.isReversed = isReversed
        self.impedanceOhm = impedanceOhm
        self.isExcited = isExcited
        self.amplitude = amplitude
        self.phaseDegrees = phaseDegrees
        self.modeIndex = modeIndex
    }

    /// Gap length for a lumped port: the span along the field direction.
    public var gapLength: Double { bounds.span(on: direction) }
}

public struct ResolvedMonitor: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let quantity: MonitorQuantity
    public let bounds: BodyBounds?
    public let planeAxis: Axis?
    public let planePosition: Double?
    public let frequenciesHertz: [Double]

    public init(
        id: UUID,
        name: String,
        quantity: MonitorQuantity,
        bounds: BodyBounds?,
        planeAxis: Axis?,
        planePosition: Double?,
        frequenciesHertz: [Double]
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.bounds = bounds
        self.planeAxis = planeAxis
        self.planePosition = planePosition
        self.frequenciesHertz = frequenciesHertz
    }
}

public struct ResolvedMeshRefinement: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let bounds: BodyBounds
    public let targetCellSize: Double

    public init(id: UUID, name: String, bounds: BodyBounds, targetCellSize: Double) {
        self.id = id
        self.name = name
        self.bounds = bounds
        self.targetCellSize = targetCellSize
    }
}

public struct ResolvedMeshPlan: Hashable, Sendable {
    /// Largest cell edge the wavelength criterion allows, project units.
    public let wavelengthLimitedCellSize: Double?
    /// Effective upper bound after applying `maxCellSize`.
    public let effectiveMaxCellSize: Double?
    public let minCellSize: Double?
    public let fixedLinesX: [Double]
    public let fixedLinesY: [Double]
    public let fixedLinesZ: [Double]
    public let refinements: [ResolvedMeshRefinement]

    public init(
        wavelengthLimitedCellSize: Double?,
        effectiveMaxCellSize: Double?,
        minCellSize: Double?,
        fixedLinesX: [Double],
        fixedLinesY: [Double],
        fixedLinesZ: [Double],
        refinements: [ResolvedMeshRefinement]
    ) {
        self.wavelengthLimitedCellSize = wavelengthLimitedCellSize
        self.effectiveMaxCellSize = effectiveMaxCellSize
        self.minCellSize = minCellSize
        self.fixedLinesX = fixedLinesX
        self.fixedLinesY = fixedLinesY
        self.fixedLinesZ = fixedLinesZ
        self.refinements = refinements
    }

    public func fixedLines(on axis: Axis) -> [Double] {
        switch axis {
        case .x: return fixedLinesX
        case .y: return fixedLinesY
        case .z: return fixedLinesZ
        }
    }

    /// Estimated cell count if the domain were filled at `effectiveMaxCellSize`.
    /// A rough order-of-magnitude figure, not a mesher.
    public func estimatedCellCount(domain: BodyBounds?) -> Int? {
        guard let domain, let cellSize = effectiveMaxCellSize, cellSize > 0 else { return nil }
        let size = domain.size
        let counts = [size.x, size.y, size.z].map { max(1.0, ($0 / cellSize).rounded(.up)) }
        let product = counts.reduce(1, *)
        guard product.isFinite, product < Double(Int.max) else { return nil }
        return Int(product)
    }
}

public struct ResolvedSimulation: Hashable, Sendable {
    /// `nil` when the domain could not be determined — an empty model with
    /// automatic sizing, or an invalid manual box.
    public let domain: BodyBounds?
    public let ports: [ResolvedPort]
    public let monitors: [ResolvedMonitor]
    public let mesh: ResolvedMeshPlan

    public init(
        domain: BodyBounds?,
        ports: [ResolvedPort],
        monitors: [ResolvedMonitor],
        mesh: ResolvedMeshPlan
    ) {
        self.domain = domain
        self.ports = ports
        self.monitors = monitors
        self.mesh = mesh
    }
}

/// The evaluated model: what the viewport draws and the exporter writes.
public struct ResolvedModel: Sendable {
    public let variables: ResolvedVariables
    /// Only bodies that resolved successfully. A body with a broken expression
    /// is absent here and carries an error diagnostic, rather than silently
    /// rendering a stale size.
    public let bodies: [ResolvedBody]
    public let bodiesByID: [UUID: ResolvedBody]
    /// Bodies that failed to resolve, so the list can badge them.
    public let failedBodyIDs: Set<UUID>
    public let simulation: ResolvedSimulation
    public let diagnostics: [Diagnostic]

    public init(
        variables: ResolvedVariables,
        bodies: [ResolvedBody],
        failedBodyIDs: Set<UUID>,
        simulation: ResolvedSimulation,
        diagnostics: [Diagnostic]
    ) {
        self.variables = variables
        self.bodies = bodies
        self.bodiesByID = Dictionary(uniqueKeysWithValues: bodies.map { ($0.id, $0) })
        self.failedBodyIDs = failedBodyIDs
        self.simulation = simulation
        self.diagnostics = diagnostics
    }

    public static let empty = ResolvedModel(
        variables: .empty,
        bodies: [],
        failedBodyIDs: [],
        simulation: ResolvedSimulation(
            domain: nil,
            ports: [],
            monitors: [],
            mesh: ResolvedMeshPlan(
                wavelengthLimitedCellSize: nil,
                effectiveMaxCellSize: nil,
                minCellSize: nil,
                fixedLinesX: [],
                fixedLinesY: [],
                fixedLinesZ: [],
                refinements: []
            )
        ),
        diagnostics: []
    )

    public func body(id: UUID?) -> ResolvedBody? {
        guard let id else { return nil }
        return bodiesByID[id]
    }

    /// Union of all visible bodies' true bounding boxes.
    public var modelBounds: BodyBounds? {
        BodyBounds.union(of: bodies.filter(\.isVisible).map(\.axisAlignedBounds))
    }

    public func diagnostics(for subject: Diagnostic.Subject) -> [Diagnostic] {
        diagnostics.forSubject(subject)
    }

    public var errorCount: Int { diagnostics.errors.count }
    public var warningCount: Int { diagnostics.warnings.count }
}
