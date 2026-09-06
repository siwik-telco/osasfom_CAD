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

public struct SimulationPort: Identifiable, Hashable, Sendable, ExpressionWalkable {
    public let id: UUID
    public var name: String
    public var kind: PortKind
    /// First terminal of a lumped port, project units. Voltage is from begin to end.
    public var begin: Vector3Expression
    /// Second terminal of a lumped port, project units.
    public var end: Vector3Expression
    /// Extent of a waveguide port. Ignored for lumped ports (the solver uses
    /// the segment `begin` → `end`).
    public var region: BoundsExpression
    /// Propagation axis for a waveguide port. For a lumped port this is
    /// inferred from `end − begin` at resolve time.
    public var direction: Axis
    /// Waveguide polarity. Lumped polarity is begin → end.
    public var isReversed: Bool
    /// Reference impedance of the lumped element, ohm. The FDTD kernel stamps
    /// this as a series resistance across the gap.
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
        begin: Vector3Expression,
        end: Vector3Expression,
        region: BoundsExpression = .zero,
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
        self.begin = begin
        self.end = end
        self.region = region
        self.direction = direction
        self.isReversed = isReversed
        self.impedanceOhm = impedanceOhm
        self.isExcited = isExcited
        self.amplitude = amplitude
        self.phaseDegrees = phaseDegrees
        self.modeIndex = modeIndex
    }

    /// Box-defined port. For a lumped port the terminals are the min and max
    /// faces along `direction` (legacy shape used before begin/end existed).
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
        let terminals = Self.terminals(from: region, direction: direction, isReversed: isReversed)
        self.init(
            id: id,
            name: name,
            kind: kind,
            begin: terminals.begin,
            end: terminals.end,
            region: region,
            direction: direction,
            isReversed: isReversed,
            impedanceOhm: impedanceOhm,
            isExcited: isExcited,
            amplitude: amplitude,
            phaseDegrees: phaseDegrees,
            modeIndex: modeIndex
        )
    }

    public mutating func walkExpressions(_ transform: (inout Expression) -> Void) {
        begin.walkExpressions(transform)
        end.walkExpressions(transform)
        region.walkExpressions(transform)
    }

    /// Min-face → max-face along `direction`, keeping the other two axes on
    /// the region's lower corner. A zero-thickness box becomes a line segment.
    public static func terminals(
        from region: BoundsExpression,
        direction: Axis,
        isReversed: Bool
    ) -> (begin: Vector3Expression, end: Vector3Expression) {
        var begin = Vector3Expression(x: region.xMin, y: region.yMin, z: region.zMin)
        var end = Vector3Expression(x: region.xMin, y: region.yMin, z: region.zMin)
        begin[direction] = isReversed ? region.upper(on: direction) : region.lower(on: direction)
        end[direction] = isReversed ? region.lower(on: direction) : region.upper(on: direction)
        return (begin, end)
    }
}

extension SimulationPort: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, begin, end, region, direction, isReversed
        case impedanceOhm, isExcited, amplitude, phaseDegrees, modeIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(PortKind.self, forKey: .kind) ?? .lumped
        region = try container.decodeIfPresent(BoundsExpression.self, forKey: .region) ?? .zero
        direction = try container.decodeIfPresent(Axis.self, forKey: .direction) ?? .y
        isReversed = try container.decodeIfPresent(Bool.self, forKey: .isReversed) ?? false
        impedanceOhm = try container.decodeIfPresent(Double.self, forKey: .impedanceOhm) ?? 50
        isExcited = try container.decodeIfPresent(Bool.self, forKey: .isExcited) ?? true
        amplitude = try container.decodeIfPresent(Double.self, forKey: .amplitude) ?? 1
        phaseDegrees = try container.decodeIfPresent(Double.self, forKey: .phaseDegrees) ?? 0
        modeIndex = try container.decodeIfPresent(Int.self, forKey: .modeIndex) ?? 1

        if let begin = try container.decodeIfPresent(Vector3Expression.self, forKey: .begin),
           let end = try container.decodeIfPresent(Vector3Expression.self, forKey: .end) {
            self.begin = begin
            self.end = end
        } else {
            let terminals = Self.terminals(from: region, direction: direction, isReversed: isReversed)
            self.begin = terminals.begin
            self.end = terminals.end
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(begin, forKey: .begin)
        try container.encode(end, forKey: .end)
        try container.encode(region, forKey: .region)
        try container.encode(direction, forKey: .direction)
        try container.encode(isReversed, forKey: .isReversed)
        try container.encode(impedanceOhm, forKey: .impedanceOhm)
        try container.encode(isExcited, forKey: .isExcited)
        try container.encode(amplitude, forKey: .amplitude)
        try container.encode(phaseDegrees, forKey: .phaseDegrees)
        try container.encode(modeIndex, forKey: .modeIndex)
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
/// What a far-field run records.
///
/// Off by default and deliberately explicit about *which* frequencies: the
/// transform accumulates a running DFT of the fields on a closed surface
/// while the run steps, so unlike the S11 sweep it cannot be re-evaluated at
/// a new frequency afterwards. Changing this list means running again.
public struct FarFieldSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// Frequencies to record, in hertz. Empty with `isEnabled` means "the
    /// band centre", so the checkbox alone is enough to get a useful result.
    public var frequenciesHertz: [Double]
    /// Angular sampling of the pattern sphere, degrees. 5° gives 37 x 72
    /// directions, which is smooth enough to read and cheap to evaluate;
    /// the cost here is the post-run transform, not the run itself.
    public var angularStepDegrees: Double

    public init(
        isEnabled: Bool = false,
        frequenciesHertz: [Double] = [],
        angularStepDegrees: Double = 5
    ) {
        self.isEnabled = isEnabled
        self.frequenciesHertz = frequenciesHertz
        self.angularStepDegrees = angularStepDegrees
    }

    /// The frequencies actually recorded, falling back to the band centre.
    public func effectiveFrequencies(in range: FrequencyRange) -> [Double] {
        guard isEnabled else { return [] }
        let requested = frequenciesHertz.filter { $0 > 0 }
        guard !requested.isEmpty else { return [range.centerHertz] }
        return requested.sorted()
    }

    /// Clamped to a range that stays useful: below 1° the transform gets slow
    /// for no visible gain, above 30° the pattern stops resembling a surface.
    public var effectiveAngularStepDegrees: Double {
        min(max(angularStepDegrees, 1), 30)
    }
}

public struct SimulationSetup: Codable, Hashable, Sendable, ExpressionWalkable {
    public var frequency: FrequencyRange
    public var domain: DomainSettings
    public var boundaries: BoundarySettings
    public var mesh: MeshSettings
    public var excitation: Excitation
    public var ports: [SimulationPort]
    public var monitors: [FieldMonitor]
    public var solver: SolverSettings
    public var farField: FarFieldSettings

    public init(
        frequency: FrequencyRange = .defaultRange,
        domain: DomainSettings = DomainSettings(),
        boundaries: BoundarySettings = .openAllSides,
        mesh: MeshSettings = MeshSettings(),
        excitation: Excitation = Excitation(),
        ports: [SimulationPort] = [],
        monitors: [FieldMonitor] = [],
        solver: SolverSettings = SolverSettings(),
        farField: FarFieldSettings = FarFieldSettings()
    ) {
        self.frequency = frequency
        self.domain = domain
        self.boundaries = boundaries
        self.mesh = mesh
        self.excitation = excitation
        self.ports = ports
        self.monitors = monitors
        self.solver = solver
        self.farField = farField
    }

    private enum CodingKeys: String, CodingKey {
        case frequency, domain, boundaries, mesh, excitation, ports, monitors, solver, farField
    }

    /// Hand-written so a project written before far-field settings existed
    /// still loads, rather than failing on the missing key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.frequency = try container.decode(FrequencyRange.self, forKey: .frequency)
        self.domain = try container.decode(DomainSettings.self, forKey: .domain)
        self.boundaries = try container.decode(BoundarySettings.self, forKey: .boundaries)
        self.mesh = try container.decode(MeshSettings.self, forKey: .mesh)
        self.excitation = try container.decode(Excitation.self, forKey: .excitation)
        self.ports = try container.decode([SimulationPort].self, forKey: .ports)
        self.monitors = try container.decode([FieldMonitor].self, forKey: .monitors)
        self.solver = try container.decode(SolverSettings.self, forKey: .solver)
        self.farField = try container.decodeIfPresent(FarFieldSettings.self, forKey: .farField) ?? FarFieldSettings()
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
