import Foundation

// MARK: - Boundaries

public enum BoundaryCondition: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Absorbing (perfectly matched layer).
    case pml
    /// Electric wall, tangential E = 0.
    case electric
    /// Magnetic wall, tangential H = 0.
    case magnetic
    /// Periodic, paired with the opposite face.
    case periodic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pml: return "PML (absorbing)"
        case .electric: return "Electric wall (PEC)"
        case .magnetic: return "Magnetic wall (PMC)"
        case .periodic: return "Periodic"
        }
    }

    public var shortName: String {
        switch self {
        case .pml: return "PML"
        case .electric: return "PEC"
        case .magnetic: return "PMC"
        case .periodic: return "Per"
        }
    }
}

/// One condition per domain face.
public struct BoundarySettings: Codable, Hashable, Sendable {
    public var xMin: BoundaryCondition
    public var xMax: BoundaryCondition
    public var yMin: BoundaryCondition
    public var yMax: BoundaryCondition
    public var zMin: BoundaryCondition
    public var zMax: BoundaryCondition
    /// Thickness of the absorbing layer, in cells.
    public var pmlCellCount: Int

    public init(
        xMin: BoundaryCondition = .pml,
        xMax: BoundaryCondition = .pml,
        yMin: BoundaryCondition = .pml,
        yMax: BoundaryCondition = .pml,
        zMin: BoundaryCondition = .pml,
        zMax: BoundaryCondition = .pml,
        pmlCellCount: Int = 8
    ) {
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
        self.zMin = zMin
        self.zMax = zMax
        self.pmlCellCount = pmlCellCount
    }

    public static let openAllSides = BoundarySettings()

    public func lower(on axis: Axis) -> BoundaryCondition {
        switch axis {
        case .x: return xMin
        case .y: return yMin
        case .z: return zMin
        }
    }

    public func upper(on axis: Axis) -> BoundaryCondition {
        switch axis {
        case .x: return xMax
        case .y: return yMax
        case .z: return zMax
        }
    }

    public mutating func setLower(_ condition: BoundaryCondition, on axis: Axis) {
        switch axis {
        case .x: xMin = condition
        case .y: yMin = condition
        case .z: zMin = condition
        }
    }

    public mutating func setUpper(_ condition: BoundaryCondition, on axis: Axis) {
        switch axis {
        case .x: xMax = condition
        case .y: yMax = condition
        case .z: zMax = condition
        }
    }

    /// Periodic boundaries only make sense as a matched pair.
    public var mismatchedPeriodicAxes: [Axis] {
        Axis.allCases.filter { axis in
            (lower(on: axis) == .periodic) != (upper(on: axis) == .periodic)
        }
    }
}

// MARK: - Domain

/// The computational volume.
public struct DomainSettings: Codable, Hashable, Sendable, ExpressionWalkable {
    public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Model bounding box grown by `padding`.
        case automatic
        /// Explicit box.
        case manual

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .automatic: return "Automatic (model + padding)"
            case .manual: return "Manual bounds"
            }
        }
    }

    public var mode: Mode
    /// Per-axis padding added on both sides in automatic mode, in project units.
    /// A quarter wavelength at the lowest frequency is the usual rule of thumb.
    public var padding: Vector3Expression
    public var manualBounds: BoundsExpression

    public init(
        mode: Mode = .automatic,
        padding: Vector3Expression = Vector3Expression(Vec3(repeating: 20)),
        manualBounds: BoundsExpression = BoundsExpression(
            BodyBounds(center: .zero, size: Vec3(repeating: 200))
        )
    ) {
        self.mode = mode
        self.padding = padding
        self.manualBounds = manualBounds
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        padding.walkExpressions(transform)
        manualBounds.walkExpressions(transform)
    }
}

// MARK: - Mesh

/// A locally refined region.
public struct MeshRefinement: Identifiable, Codable, Hashable, Sendable, ExpressionWalkable {
    public let id: UUID
    public var name: String
    public var region: BoundsExpression
    /// Target edge length inside the region, in project units.
    public var targetCellSize: Expression
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        region: BoundsExpression,
        targetCellSize: Expression,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.region = region
        self.targetCellSize = targetCellSize
        self.isEnabled = isEnabled
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        region.walkExpressions(transform)
        transform(&targetCellSize)
    }
}

public struct MeshSettings: Codable, Hashable, Sendable, ExpressionWalkable {
    /// Cells per wavelength at the highest simulated frequency, in the densest
    /// material present. 10–20 is typical.
    public var cellsPerWavelength: Double
    /// Hard upper bound on edge length, project units. Empty means "derive from
    /// `cellsPerWavelength`".
    public var maxCellSize: Expression
    /// Hard lower bound, project units. Empty means unconstrained. Guards
    /// against a thin feature driving the time step to nothing.
    public var minCellSize: Expression
    /// Largest allowed ratio between neighbouring cell sizes.
    public var maxGrowthRatio: Double
    /// Force grid lines at body faces, so material boundaries land on cell edges.
    public var snapToBodyEdges: Bool
    /// User-pinned grid lines, project units.
    public var fixedLinesX: [Expression]
    public var fixedLinesY: [Expression]
    public var fixedLinesZ: [Expression]
    public var refinements: [MeshRefinement]

    public init(
        cellsPerWavelength: Double = 20,
        maxCellSize: Expression = .unset,
        minCellSize: Expression = .unset,
        maxGrowthRatio: Double = 1.4,
        snapToBodyEdges: Bool = true,
        fixedLinesX: [Expression] = [],
        fixedLinesY: [Expression] = [],
        fixedLinesZ: [Expression] = [],
        refinements: [MeshRefinement] = []
    ) {
        self.cellsPerWavelength = cellsPerWavelength
        self.maxCellSize = maxCellSize
        self.minCellSize = minCellSize
        self.maxGrowthRatio = maxGrowthRatio
        self.snapToBodyEdges = snapToBodyEdges
        self.fixedLinesX = fixedLinesX
        self.fixedLinesY = fixedLinesY
        self.fixedLinesZ = fixedLinesZ
        self.refinements = refinements
    }

    public func fixedLines(on axis: Axis) -> [Expression] {
        switch axis {
        case .x: return fixedLinesX
        case .y: return fixedLinesY
        case .z: return fixedLinesZ
        }
    }

    public mutating func setFixedLines(_ lines: [Expression], on axis: Axis) {
        switch axis {
        case .x: fixedLinesX = lines
        case .y: fixedLinesY = lines
        case .z: fixedLinesZ = lines
        }
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        transform(&maxCellSize)
        transform(&minCellSize)
        for index in fixedLinesX.indices { transform(&fixedLinesX[index]) }
        for index in fixedLinesY.indices { transform(&fixedLinesY[index]) }
        for index in fixedLinesZ.indices { transform(&fixedLinesZ[index]) }
        for index in refinements.indices { refinements[index].walkExpressions(transform) }
    }
}

// MARK: - Excitation

public struct FrequencyRange: Codable, Hashable, Sendable {
    public var minimumHertz: Double
    public var maximumHertz: Double

    public init(minimumHertz: Double, maximumHertz: Double) {
        self.minimumHertz = minimumHertz
        self.maximumHertz = maximumHertz
    }

    public static let defaultRange = FrequencyRange(minimumHertz: 1e9, maximumHertz: 5e9)

    public var centerHertz: Double { (minimumHertz + maximumHertz) / 2 }
    public var bandwidthHertz: Double { maximumHertz - minimumHertz }
    public var isValid: Bool { minimumHertz > 0 && maximumHertz > minimumHertz }

    public var description: String {
        "\(FrequencyFormatter.string(hertz: minimumHertz)) – \(FrequencyFormatter.string(hertz: maximumHertz))"
    }
}

public enum ExcitationWaveform: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Broadband Gaussian pulse spanning the frequency range.
    case gaussianPulse
    /// Single-frequency sine, for steady-state runs.
    case sinusoidal
    /// Step with a smooth rise.
    case step

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gaussianPulse: return "Gaussian pulse (broadband)"
        case .sinusoidal: return "Sinusoidal (single frequency)"
        case .step: return "Step"
        }
    }

    public var usesFrequencyRange: Bool { self == .gaussianPulse }
}

public struct Excitation: Codable, Hashable, Sendable {
    public var waveform: ExcitationWaveform
    /// Drive frequency for `sinusoidal`; ignored for broadband waveforms.
    public var sinusoidalHertz: Double
    /// Rise time in seconds for `step`.
    public var stepRiseTimeSeconds: Double

    public init(
        waveform: ExcitationWaveform = .gaussianPulse,
        sinusoidalHertz: Double = 2.4e9,
        stepRiseTimeSeconds: Double = 1e-11
    ) {
        self.waveform = waveform
        self.sinusoidalHertz = sinusoidalHertz
        self.stepRiseTimeSeconds = stepRiseTimeSeconds
    }
}

// MARK: - Ports

public enum PortKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Lumped element spanning a gap, with a series resistance.
    case lumped
    /// Waveguide/mode port on a cross-section.
    case waveguide

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lumped: return "Lumped port"
        case .waveguide: return "Waveguide port"
        }
    }
}

public struct SimulationPort: Identifiable, Codable, Hashable, Sendable, ExpressionWalkable {
    public let id: UUID
    public var name: String
    public var kind: PortKind
    /// Extent of the port. For a lumped port this is the gap it bridges; the
    /// span along `direction` is the gap length.
    public var region: BoundsExpression
    /// Field orientation for a lumped port; propagation axis for a waveguide port.
    public var direction: Axis
    /// Positive means the field points along +`direction`.
    public var isReversed: Bool
    /// Reference impedance, ohm.
    public var impedanceOhm: Double
    /// Whether this port drives the simulation. S-parameters are still recorded
    /// for passive ports.
    public var isExcited: Bool
    public var amplitude: Double
    public var phaseDegrees: Double
    /// Mode index for waveguide ports (1 = fundamental).
    public var modeIndex: Int

    public init(
        id: UUID = UUID(),
        name: String,
        kind: PortKind = .lumped,
        region: BoundsExpression,
        direction: Axis = .y,
        isReversed: Bool = false,
        impedanceOhm: Double = 50,
        isExcited: Bool = true,
        amplitude: Double = 1,
        phaseDegrees: Double = 0,
        modeIndex: Int = 1
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.region = region
        self.direction = direction
        self.isReversed = isReversed
        self.impedanceOhm = impedanceOhm
        self.isExcited = isExcited
        self.amplitude = amplitude
        self.phaseDegrees = phaseDegrees
        self.modeIndex = modeIndex
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        region.walkExpressions(transform)
    }
}

// MARK: - Monitors

public enum MonitorQuantity: String, Codable, CaseIterable, Identifiable, Sendable {
    case electricField
    case magneticField
    case currentDensity
    case power
    case farField

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .electricField: return "E-field"
        case .magneticField: return "H-field"
        case .currentDensity: return "Current density"
        case .power: return "Power flow"
        case .farField: return "Far field"
        }
    }

    /// Far-field results are only meaningful over the whole domain.
    public var requiresWholeDomain: Bool { self == .farField }
}

public enum MonitorRegion: Codable, Hashable, Sendable, ExpressionWalkable {
    case wholeDomain
    case box(BoundsExpression)
    /// A cut plane at `position` along `axis`.
    case plane(axis: Axis, position: Expression)

    public var displayName: String {
        switch self {
        case .wholeDomain: return "Whole domain"
        case .box: return "Box"
        case .plane(let axis, _): return "\(axis.displayName) plane"
        }
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        switch self {
        case .wholeDomain:
            break
        case .box(var bounds):
            bounds.walkExpressions(transform)
            self = .box(bounds)
        case .plane(let axis, var position):
            transform(&position)
            self = .plane(axis: axis, position: position)
        }
    }
}

public struct FieldMonitor: Identifiable, Codable, Hashable, Sendable, ExpressionWalkable {
    public let id: UUID
    public var name: String
    public var quantity: MonitorQuantity
    public var region: MonitorRegion
    /// Frequencies to record, Hz. Empty means record in the time domain instead.
    public var frequenciesHertz: [Double]
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        quantity: MonitorQuantity,
        region: MonitorRegion = .wholeDomain,
        frequenciesHertz: [Double] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.region = region
        self.frequenciesHertz = frequenciesHertz
        self.isEnabled = isEnabled
    }

    public var isTimeDomain: Bool { frequenciesHertz.isEmpty }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        region.walkExpressions(transform)
    }
}

// MARK: - Solver

public struct SolverSettings: Codable, Hashable, Sendable {
    /// Stop once the residual energy has decayed by this many dB. Negative.
    public var energyDecayDecibels: Double
    /// Hard cap on time steps, regardless of the decay criterion.
    public var maximumTimeSteps: Int
    /// Fraction of the Courant limit to use for the time step.
    public var courantFactor: Double

    public init(
        energyDecayDecibels: Double = -40,
        maximumTimeSteps: Int = 200_000,
        courantFactor: Double = 0.98
    ) {
        self.energyDecayDecibels = energyDecayDecibels
        self.maximumTimeSteps = maximumTimeSteps
        self.courantFactor = courantFactor
    }
}

/// Everything the solver needs that is not geometry.
///
/// This existed nowhere before, which meant a body-only export could not
/// actually be run. It lives in the model — not the UI — so it is versioned,
/// validated and exported alongside the geometry.
public struct SimulationSetup: Codable, Hashable, Sendable, ExpressionWalkable {
    public var frequency: FrequencyRange
    public var domain: DomainSettings
    public var boundaries: BoundarySettings
    public var mesh: MeshSettings
    public var excitation: Excitation
    public var ports: [SimulationPort]
    public var monitors: [FieldMonitor]
    public var solver: SolverSettings

    public init(
        frequency: FrequencyRange = .defaultRange,
        domain: DomainSettings = DomainSettings(),
        boundaries: BoundarySettings = .openAllSides,
        mesh: MeshSettings = MeshSettings(),
        excitation: Excitation = Excitation(),
        ports: [SimulationPort] = [],
        monitors: [FieldMonitor] = [],
        solver: SolverSettings = SolverSettings()
    ) {
        self.frequency = frequency
        self.domain = domain
        self.boundaries = boundaries
        self.mesh = mesh
        self.excitation = excitation
        self.ports = ports
        self.monitors = monitors
        self.solver = solver
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        domain.walkExpressions(transform)
        mesh.walkExpressions(transform)
        for index in ports.indices { ports[index].walkExpressions(transform) }
        for index in monitors.indices { monitors[index].walkExpressions(transform) }
    }

    /// Sensible defaults for a new project: a broadband run with a far-field
    /// monitor at the band centre.
    public static func makeDefault() -> SimulationSetup {
        var setup = SimulationSetup()
        setup.monitors = [
            FieldMonitor(
                name: "Far field",
                quantity: .farField,
                region: .wholeDomain,
                frequenciesHertz: [setup.frequency.centerHertz]
            )
        ]
        return setup
    }
}
