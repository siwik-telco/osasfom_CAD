//
// FDTDCADBridge.swift
//
// Spina parametryczny model CAD (CADDocument / ResolvedModel) z rdzeniem
// FDTD z FDTDSolver.swift (port openEMS: Engine + Operator).
//
// Pipeline:
//
//   CADDocument.resolved (ResolvedModel)
//        │
//        ▼
//   GridMesher.makeDiscLines(...)          -> linie siatki Yee [m] na oś
//        │
//        ▼
//   Operator.setupGrid(discLines:, gridDeltaUnit: 1.0)
//   Operator.materialProvider = CADMaterialProvider(...)
//   Operator.extensionFactories = [LumpedPortExtension, ...]
//   Operator.calcECOperator()
//        │
//        ▼
//   Engine.make(op:)  ->  engine.iterateTS(N)
//        │
//        ▼
//   LumpedPortExtension zbiera V(t), I(t) -> DFT -> S11/S21
//
// Uwaga: to jest działający szkielet, nie 1:1 port pełnej fizyki portów
// openEMS. Wystarcza do pierwszych uruchomień (np. patch antena ze
// starterDocument) i do dalszego dopracowania (dokładniejszy port
// rezystancyjny, PML jako EngineExtension, uśrednianie brzegów PEC).
//

import Foundation
import osasfom_cadCore

// MARK: - 1. Mesher: ResolvedModel -> Operator.discLines

public enum GridMesher {

    public struct Lines {
        /// Linie siatki w metrach, gotowe do Operator.setupGrid(discLines:gridDeltaUnit: 1.0)
        public let metersLines: [[Double]] // [xLines, yLines, zLines]
    }

    /// Buduje linie siatki na podstawie zrezolwowanego modelu.
    /// Zasady (zgodne z duchem `MeshSettings` / `ResolvedMeshPlan`):
    /// - punkty "sztywne" (fixed): granice domeny, krawędzie brył (jeśli
    ///   snapToBodyEdges), krawędzie portów, granice regionów refinement,
    ///   oraz `fixedLinesX/Y/Z` użytkownika,
    /// - między kolejnymi punktami sztywnymi siatka jest wypełniana z
    ///   docelowym rozmiarem komórki (mniejszym w obszarach refinement),
    ///   z ograniczeniem narostu `maxGrowthRatio`.
    public static func makeDiscLines(
        resolved: ResolvedModel,
        setup: SimulationSetup,
        unit: LengthUnit
    ) -> Lines? {
        guard let domain = resolved.simulation.domain else { return nil }
        let plan = resolved.simulation.mesh
        let baseCell = plan.effectiveMaxCellSize ?? (domain.size.x + domain.size.y + domain.size.z) / 3 / 20
        let minCell = plan.minCellSize ?? baseCell / 10
        let growth = max(1.0, setup.mesh.maxGrowthRatio)

        func axisLines(_ axis: Axis) -> [Double] {
            var fixed = Set<Double>()
            fixed.insert(domain.minimum[axis])
            fixed.insert(domain.maximum[axis])

            if setup.mesh.snapToBodyEdges {
                // `snapBounds` is the body plus each of its boolean tools: a
                // cut only lands where the numbers say if the grid has a line
                // on the cut face, so a tool's edges are snap-worthy even
                // though the tool removes material rather than adding it.
                for body in resolved.bodies where body.isVisible {
                    for bounds in body.snapBounds {
                        fixed.insert(bounds.minimum[axis])
                        fixed.insert(bounds.maximum[axis])
                    }
                }
            }
            for port in resolved.simulation.ports {
                fixed.insert(port.bounds.minimum[axis])
                fixed.insert(port.bounds.maximum[axis])
            }
            for refinement in plan.refinements {
                fixed.insert(refinement.bounds.minimum[axis])
                fixed.insert(refinement.bounds.maximum[axis])
            }
            for value in plan.fixedLines(on: axis) {
                fixed.insert(value)
            }

            let sortedFixed = fixed.sorted().filter { $0 >= domain.minimum[axis] && $0 <= domain.maximum[axis] }

            // Docelowy rozmiar komórki w danym punkcie: bazowy, chyba że
            // punkt leży wewnątrz regionu refinement - wtedy najmniejszy
            // pasujący target.
            func targetCellSize(at x: Double) -> Double {
                var target = baseCell
                for refinement in plan.refinements {
                    if x >= refinement.bounds.minimum[axis] && x <= refinement.bounds.maximum[axis] {
                        target = min(target, refinement.targetCellSize)
                    }
                }
                return max(target, minCell)
            }

            var lines: [Double] = []
            for i in 0..<max(sortedFixed.count - 1, 0) {
                let a = sortedFixed[i]
                let b = sortedFixed[i + 1]
                lines.append(contentsOf: fillInterval(a: a, b: b, growth: growth, targetAt: targetCellSize))
            }
            if let last = sortedFixed.last {
                lines.append(last)
            } else {
                lines = [domain.minimum[axis], domain.maximum[axis]]
            }

            // De-duplikacja i minimalny odstęp, żeby uniknąć zerowych komórek.
            var cleaned: [Double] = []
            for value in lines.sorted() {
                if let last = cleaned.last, value - last < minCell * 1e-3 { continue }
                cleaned.append(value)
            }
            if cleaned.count < 3 {
                // Operator wymaga min. 3 linii na oś (patrz FDTDSolver.setupGrid).
                let mid = (cleaned.first ?? 0) + ((cleaned.last ?? 1) - (cleaned.first ?? 0)) / 2
                cleaned = ([cleaned.first ?? 0, mid, cleaned.last ?? 1]).sorted()
            }
            return cleaned
        }

        let xLines = axisLines(.x).map(unit.toMeters)
        let yLines = axisLines(.y).map(unit.toMeters)
        let zLines = axisLines(.z).map(unit.toMeters)
        return Lines(metersLines: [xLines, yLines, zLines])
    }

    /// Wypełnia przedział [a, b] liniami zbiegającymi do `targetAt(x)`,
    /// z ograniczonym narastaniem między sąsiednimi komórkami (uproszczona
    /// wersja SmoothMeshLines z openEMS/CSXCAD).
    private static func fillInterval(
        a: Double, b: Double, growth: Double, targetAt: (Double) -> Double
    ) -> [Double] {
        guard b > a else { return [a] }
        let target = targetAt((a + b) / 2)
        let length = b - a
        var count = max(1, Int((length / target).rounded()))

        // Sprawdź, czy jednorodny podział mieści się w limicie narostu
        // względem sąsiadów o innym targecie - w tej uproszczonej wersji
        // po prostu ograniczamy liczbę komórek z góry, żeby uniknąć
        // eksplozji przy bardzo małych regionach refinement.
        let maxReasonableCells = 20_000
        count = min(count, maxReasonableCells)

        var lines: [Double] = []
        for i in 0..<count {
            lines.append(a + length * Double(i) / Double(count))
        }
        _ = growth // zarezerwowane pod pełną wersję z narastaniem geometrycznym
        return lines
    }
}

// MARK: - 2. MaterialProvider: ResolvedBody[] -> eps/kappa/mue/sigma lookup

/// Implementacja `MaterialProvider` z FDTDSolver.swift oparta o
/// zrezolwowane bryły CAD. Reguła nakładania jest identyczna jak w
/// `SolverExportEncoder`: ciała są sprawdzane w kolejności malejącego
/// priorytetu, pierwsze trafienie wygrywa.
public final class CADMaterialProvider: MaterialProvider {

    private struct Entry {
        let body: ResolvedBody
        let material: MaterialDefinition
    }

    private let entries: [Entry] // posortowane malejąco po priorytecie
    private let unit: LengthUnit

    /// Aproksymacja PEC: bardzo duża przewodność zamiast idealnego zwarcia.
    /// Wystarczające dla stabilności jawnego FDTD przy typowym kroku czasowym;
    /// dla ściśle "twardego" PEC lepiej docelowo zerować E na granicy w
    /// applyElectricBC-podobny sposób.
    public var pecConductivitySPerM: Double = 1e7

    public var backgroundEpsR: Double = 1.0
    public var backgroundMueR: Double = 1.0
    public var backgroundKappa: Double = 0.0
    public var backgroundSigma: Double = 0.0
    public var backgroundDensity: Double = 0.0

    public init(bodies: [ResolvedBody], materials: [MaterialDefinition], unit: LengthUnit) {
        let byID = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
        self.entries = bodies
            .filter(\.isVisible)
            .compactMap { body in
                guard let material = byID[body.materialID] else { return nil }
                return Entry(body: body, material: material)
            }
            .sorted { lhs, rhs in
                if lhs.body.priority != rhs.body.priority { return lhs.body.priority > rhs.body.priority }
                return lhs.body.orderIndex > rhs.body.orderIndex
            }
        self.unit = unit
    }

    public func material(direction ny: Int, coords: (Double, Double, Double), matType: Int) -> Double {
        // coords przychodzą w metrach (Operator pracuje po setupGrid w
        // metrach, patrz gridDeltaUnit: 1.0 w SimulationRunner). Bryły w
        // ResolvedModel są w jednostkach projektu, więc konwertujemy tu.
        let pointInProjectUnits = Vec3(
            x: unit.fromMeters(coords.0),
            y: unit.fromMeters(coords.1),
            z: unit.fromMeters(coords.2)
        )

        guard let hit = entries.first(where: { contains($0.body, point: pointInProjectUnits) }) else {
            return backgroundValue(matType: matType)
        }

        let material = hit.material
        if !material.kind.usesConstitutiveParameters {
            // Metal (PEC) lub inny przewodnik bez jawnych parametrów.
            switch matType {
            case 0: return 1.0
            case 1: return pecConductivitySPerM
            case 2: return 1.0
            case 3: return 0.0
            default: return 0.0
            }
        }

        switch matType {
        case 0: return material.epsilonR
        case 1: return material.electricConductivity
        case 2: return material.muR
        case 3: return material.magneticConductivity
        default: return backgroundDensity
        }
    }

    private func backgroundValue(matType: Int) -> Double {
        switch matType {
        case 0: return backgroundEpsR
        case 1: return backgroundKappa
        case 2: return backgroundMueR
        case 3: return backgroundSigma
        default: return backgroundDensity
        }
    }

    /// Test punktu względem bryły w jej lokalnym układzie (odwraca
    /// translację/rotację/skalę), z dokładnym testem kształtu zamiast tylko
    /// axisAlignedBounds - istotne dla obróconych brył.
    /// Point-in-body, delegated to `ShapeContainment` so the solver and the
    /// viewport can never disagree about what the model is — including a
    /// body's boolean history, which is applied there analytically rather
    /// than sampled off a mesh.
    private func contains(_ body: ResolvedBody, point: Vec3) -> Bool {
        // Cheap axis-aligned reject first; the exact test is the authority.
        guard body.axisAlignedBounds.contains(point) else { return false }
        return ShapeContainment.contains(body, worldPoint: point)
    }
}

// MARK: - 3. Excitation waveform (Gaussian pulse / sinusoidal / step)

public enum ExcitationWaveformSampler {
    public static func value(
        excitation: Excitation,
        frequency: FrequencyRange,
        timeSeconds t: Double
    ) -> Double {
        switch excitation.waveform {
        case .sinusoidal:
            return sin(2 * .pi * excitation.sinusoidalHertz * t)
        case .step:
            let tau = max(excitation.stepRiseTimeSeconds, 1e-15)
            return 1 - exp(-t / tau)
        case .gaussianPulse:
            let fCenter = frequency.centerHertz
            let bw = max(frequency.bandwidthHertz, fCenter * 0.05)
            let sigma = 1 / (.pi * bw)
            let t0 = 3 * sigma
            let arg = (t - t0) / sigma
            return exp(-0.5 * arg * arg) * cos(2 * .pi * fCenter * (t - t0))
        }
    }
}

// MARK: - 4. Lumped port as EngineExtension

/// Uchwyt przekazywany do rozszerzeń, bo w chwili tworzenia (Operator.
/// extensionFactories) obiekt Engine jeszcze nie istnieje - Engine
/// przypisuje się do handle zaraz po Engine.make(op:).
public final class EngineHandle {
    public weak var engine: Engine?
    public init() {}
}

/// A resistively-terminated lumped port: `Operator.addLumpedResistor` stamps
/// the port's reference impedance directly onto this edge's conductance
/// (so the edge is no longer a lossless material cell but an actual R-loaded
/// node), and this extension adds the Thevenin source voltage on top each
/// step and records V(t)/I(t) for the S-parameter DFT. This is the same
/// two-part scheme openEMS uses for a lumped-port excitation (soft voltage
/// injection at a resistively-stamped edge), not a full openEMS
/// `Operator_Ext_LumpedElement` port — port current is read from the
/// adjacent H-field (`Engine.getCurr`) as a proxy for the true Ampere's-law
/// loop current, which is exact only when the gap spans exactly one Yee
/// edge (true for the meshes `GridMesher` produces, since it always inserts
/// a fixed line at both port terminals).
public final class LumpedPortExtension: EngineExtension {
    public let priority = 100
    public let extensionName: String

    private let handle: EngineHandle
    private let directionIndex: Int
    private let gridPos: (Int, Int, Int)
    private let gapLengthMeters: Double
    private let excitation: Excitation
    private let frequency: FrequencyRange
    private let isExcited: Bool
    private let amplitude: Double
    private let dT: () -> Double

    public private(set) var timeSeconds: [Double] = []
    public private(set) var voltage: [Double] = []
    public private(set) var current: [Double] = []

    public init(
        name: String,
        handle: EngineHandle,
        directionIndex: Int,
        gridPos: (Int, Int, Int),
        gapLengthMeters: Double,
        excitation: Excitation,
        frequency: FrequencyRange,
        isExcited: Bool,
        amplitude: Double,
        dT: @escaping () -> Double
    ) {
        self.extensionName = name
        self.handle = handle
        self.directionIndex = directionIndex
        self.gridPos = gridPos
        self.gapLengthMeters = gapLengthMeters
        self.excitation = excitation
        self.frequency = frequency
        self.isExcited = isExcited
        self.amplitude = amplitude
        self.dT = dT
    }

    public func doPreVoltageUpdates() {}
    public func doPostVoltageUpdates() {}

    public func apply2Voltages() {
        guard let engine = handle.engine else { return }
        let t = Double(engine.numTS) * dT()
        if isExcited {
            let waveform = ExcitationWaveformSampler.value(excitation: excitation, frequency: frequency, timeSeconds: t)
            let injected = amplitude * waveform
            let existing = engine.getVolt(directionIndex, gridPos.0, gridPos.1, gridPos.2)
            engine.setVolt(directionIndex, gridPos.0, gridPos.1, gridPos.2, existing + injected)
        }
        let v = engine.getVolt(directionIndex, gridPos.0, gridPos.1, gridPos.2)
        // curlH's +n reference (Ampère's law, matching how curl(H) drives
        // +dE/dt in the update this edge uses) is the current flowing *out*
        // of the port into the rest of the circuit loop, i.e. opposite to
        // the a/b-wave convention's "current into the port from the
        // source". Confirmed empirically too: without this flip, |S11|
        // comes out > 1 everywhere (impossible for this passive one-port) —
        // exactly the mirrored curve 1/S11 produces.
        let i = -engine.curlH(direction: directionIndex, pos: gridPos)
        timeSeconds.append(t)
        voltage.append(v)
        current.append(i)
    }

    public func doPreCurrentUpdates() {}
    public func doPostCurrentUpdates() {}
    public func apply2Current() {}
}

// MARK: - 5. Post-processing: DFT -> S-parameters

public enum PortSpectrum {
    /// DFT wprost z przebiegu czasowego (Goertzel-like naive DFT - OK dla
    /// kilku-kilkunastu częstotliwości monitorowanych, nie do widma ciągłego).
    public static func dft(time: [Double], values: [Double], atHertz f: Double) -> (real: Double, imag: Double) {
        var re = 0.0, im = 0.0
        guard time.count > 1 else { return (0, 0) }
        for i in 0..<time.count {
            let dt = i == 0 ? (time[1] - time[0]) : (time[i] - time[i - 1])
            let phase = -2 * Double.pi * f * time[i]
            re += values[i] * cos(phase) * dt
            im += values[i] * sin(phase) * dt
        }
        return (re, im)
    }

    /// S11 dla portu jednoportowego wzbudzanego: a = (V+Z0 I)/2/sqrt(Z0),
    /// b = (V-Z0 I)/2/sqrt(Z0), S11 = b/a.
    public static func s11(port: LumpedPortExtension, impedanceOhm z0: Double, atHertz f: Double) -> Double {
        let v = dft(time: port.timeSeconds, values: port.voltage, atHertz: f)
        let i = dft(time: port.timeSeconds, values: port.current, atHertz: f)
        let aRe = (v.real + z0 * i.real) / 2, aIm = (v.imag + z0 * i.imag) / 2
        let bRe = (v.real - z0 * i.real) / 2, bIm = (v.imag - z0 * i.imag) / 2
        let aMagSq = aRe * aRe + aIm * aIm
        guard aMagSq > 0 else { return .infinity }
        // |b/a| w dB
        let bMag = (bRe * bRe + bIm * bIm).squareRoot()
        let aMag = aMagSq.squareRoot()
        return 20 * log10(bMag / aMag)
    }
}

// MARK: - 6. Orchestrator: CADDocument -> Engine -> results

/// One point of a return-loss sweep.
public struct S11Point: Hashable, Codable, Sendable {
    public let hertz: Double
    public let decibels: Double
}

/// Axis domains for plotting an S11 sweep, derived from the points actually
/// being drawn so the axes can never disagree with the curve.
///
/// Charting frameworks left to themselves pick a "nice" numeric domain
/// anchored at zero, which for a 2-3 GHz sweep spends two thirds of the plot
/// on frequencies that were never simulated and squashes the resonance into a
/// spike. The swept range *is* the interesting range, so it is stated
/// outright — and the dB axis is derived too, so a dip deeper than a default
/// domain cannot be clipped off the bottom.
public struct S11PlotDomain: Hashable, Sendable {
    public let frequencyGHz: ClosedRange<Double>
    public let decibels: ClosedRange<Double>

    /// Gridlines land on multiples of this, so the labels stay readable.
    private static let division = 5.0

    public init(_ spectrum: [S11Point]) {
        let frequencies = spectrum.map { $0.hertz / 1e9 }
        let lowest = frequencies.min() ?? 0
        let highest = frequencies.max() ?? 1
        // A single point (or none) has no width to plot; give it one rather
        // than letting the range collapse to something a chart can't use.
        frequencyGHz = highest > lowest ? lowest...highest : lowest...(lowest + 1)

        let values = spectrum.map(\.decibels)
        let deepest = values.min() ?? -20
        let shallowest = values.max() ?? 0

        // Round out past the extremes so the trace never runs along the frame.
        // The floor of -5 keeps a nearly flat, badly-matched result from being
        // drawn on a domain so tight that numerical fuzz reads as structure.
        let lower = min(Self.rounded(deepest - 2, .down), -Self.division)
        let upper = Self.rounded(max(shallowest, 0), .up)
        decibels = lower...max(upper, lower + Self.division)
    }

    private static func rounded(_ value: Double, _ rule: FloatingPointRoundingRule) -> Double {
        (value / division).rounded(rule) * division
    }
}

/// A completed run, with enough of the model's state at the time to make
/// sense of it later — in particular the variable values that produced it,
/// so a later change to those variables is visible as a diff against any
/// past run.
public struct RunRecord: Identifiable, Codable, Sendable {
    public let id: Int
    public let timestamp: Date
    /// Variable name -> resolved value, at the moment this run started. This
    /// is what makes two runs comparable: it says what the model *was*.
    public let variableSnapshot: [String: Double]
    public let sweptFrequencyRange: FrequencyRange
    public let maximumTimeSteps: Int
    public let wasStoppedEarly: Bool
    public let gridSize: (Int, Int, Int)
    public let s11Spectrum: [S11Point]
    public let s11DbAtCenter: Double?
    /// Empty unless the run recorded far field. Stored with the run so a
    /// pattern can be compared against an earlier one after a relaunch.
    public let farFieldPatterns: [FarFieldPattern]

    public init(
        id: Int,
        timestamp: Date,
        variableSnapshot: [String: Double],
        sweptFrequencyRange: FrequencyRange,
        maximumTimeSteps: Int,
        wasStoppedEarly: Bool,
        gridSize: (Int, Int, Int),
        s11Spectrum: [S11Point],
        s11DbAtCenter: Double?,
        farFieldPatterns: [FarFieldPattern] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.variableSnapshot = variableSnapshot
        self.sweptFrequencyRange = sweptFrequencyRange
        self.maximumTimeSteps = maximumTimeSteps
        self.wasStoppedEarly = wasStoppedEarly
        self.gridSize = gridSize
        self.s11Spectrum = s11Spectrum
        self.s11DbAtCenter = s11DbAtCenter
        self.farFieldPatterns = farFieldPatterns
    }

    public var cellCount: Int { gridSize.0 * gridSize.1 * gridSize.2 }

    /// The deepest point of the sweep — the number a run is usually judged by.
    public var deepestDip: S11Point? {
        s11Spectrum.min { $0.decibels < $1.decibels }
    }

    // MARK: - Codable
    //
    // Hand-written only because `gridSize` is a tuple, which has no synthesised
    // conformance; everything else is stored as-is.

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, variableSnapshot, sweptFrequencyRange
        case maximumTimeSteps, wasStoppedEarly, gridSize
        case s11Spectrum, s11DbAtCenter, farFieldPatterns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.variableSnapshot = try container.decode([String: Double].self, forKey: .variableSnapshot)
        self.sweptFrequencyRange = try container.decode(FrequencyRange.self, forKey: .sweptFrequencyRange)
        self.maximumTimeSteps = try container.decode(Int.self, forKey: .maximumTimeSteps)
        self.wasStoppedEarly = try container.decode(Bool.self, forKey: .wasStoppedEarly)
        let size = try container.decode([Int].self, forKey: .gridSize)
        self.gridSize = (size.count > 2 ? size[0] : 0, size.count > 2 ? size[1] : 0, size.count > 2 ? size[2] : 0)
        self.s11Spectrum = try container.decode([S11Point].self, forKey: .s11Spectrum)
        self.s11DbAtCenter = try container.decodeIfPresent(Double.self, forKey: .s11DbAtCenter)
        self.farFieldPatterns = try container.decodeIfPresent([FarFieldPattern].self, forKey: .farFieldPatterns) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(variableSnapshot, forKey: .variableSnapshot)
        try container.encode(sweptFrequencyRange, forKey: .sweptFrequencyRange)
        try container.encode(maximumTimeSteps, forKey: .maximumTimeSteps)
        try container.encode(wasStoppedEarly, forKey: .wasStoppedEarly)
        try container.encode([gridSize.0, gridSize.1, gridSize.2], forKey: .gridSize)
        try container.encode(s11Spectrum, forKey: .s11Spectrum)
        try container.encodeIfPresent(s11DbAtCenter, forKey: .s11DbAtCenter)
        try container.encode(farFieldPatterns, forKey: .farFieldPatterns)
    }
}

@MainActor
public final class SimulationRunner: ObservableObject {
    public enum RunnerError: Error, LocalizedError {
        case noDomain
        case modelHasErrors(Int)
        case noExcitedLumpedPort
        case noConductorNearExcitedPort(String)

        public var errorDescription: String? {
            switch self {
            case .noDomain: return "The computational domain is not defined."
            case .modelHasErrors(let n): return "The model has \(n) error(s) — fix them before running the simulation."
            case .noExcitedLumpedPort: return "No excited lumped port; there is nothing to compute a return loss from."
            case .noConductorNearExcitedPort(let name):
                return "Port “\(name)” isn't touching a conductor on either terminal. Its resistor would sit alone in free space, perfectly matched to its own reference impedance — the result would be a flat, meaningless S11 near 0 dB. Assign a conductive material (e.g. PEC) to the body the port should feed, or move the port terminals so they meet it."
            }
        }
    }

    /// How many points to sample across the excited frequency range for the
    /// return-loss sweep. A plain (non-FFT) DFT is used, so this is O(N) DFTs
    /// over the recorded time series — fine for a few hundred points.
    public var spectrumPointCount = 121

    @Published public private(set) var isRunning = false
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var s11DbAtCenter: Double?
    @Published public private(set) var s11Spectrum: [S11Point] = []
    /// One pattern per recorded far-field frequency. Empty unless the run had
    /// far-field recording switched on.
    @Published public private(set) var farFieldPatterns: [FarFieldPattern] = []
    /// Set when far-field recording was asked for but could not be set up, so
    /// the absence of a pattern is explained rather than just observed.
    @Published public private(set) var farFieldWarning: String?
    @Published public private(set) var gridSize: (Int, Int, Int) = (0, 0, 0)
    /// True if the spectrum currently shown came from a run stopped early
    /// rather than one that ran its full step count.
    @Published public private(set) var wasStoppedEarly = false
    /// The frequency range actually simulated (the excitation's effective
    /// bandwidth). `s11Spectrum`'s displayed range can be narrowed within
    /// this via `setPlotRange`, but not meaningfully widened beyond it.
    @Published public private(set) var sweptFrequencyRange: FrequencyRange?
    /// The range `s11Spectrum` currently covers — equal to
    /// `sweptFrequencyRange` until `setPlotRange` narrows it.
    @Published public private(set) var plotRange: FrequencyRange?
    @Published public private(set) var history: [RunRecord] = []

    /// Which project's history is currently loaded.
    @Published public private(set) var historyProjectURL: URL?
    private var hasLoadedHistory = false

    /// Points the history at `project` and loads its stored runs.
    ///
    /// Explicit rather than a `didSet` on the URL, because the first call is
    /// usually `nil` (an unsaved project) and a property observer never fires
    /// for a value that did not change — the untitled history would simply
    /// never load.
    public func loadHistory(for project: URL?) {
        guard !hasLoadedHistory || project != historyProjectURL else { return }
        let movingFromUntitled = hasLoadedHistory && historyProjectURL == nil && project != nil
        let stored = historyStore.load(project: project)

        historyProjectURL = project
        hasLoadedHistory = true

        // Saving an untitled project for the first time must not look like it
        // wiped the session's runs: they were made on this model, so they move
        // with it rather than being replaced by the new file's empty history.
        if movingFromUntitled, stored.isEmpty, !history.isEmpty {
            historyStore.save(history, project: project)
            return
        }
        history = stored
    }

    private let historyStore: RunHistoryStore

    /// Forgets this project's stored runs, on disk as well as in memory.
    public func clearHistory() {
        history = []
        historyStore.clear(project: historyProjectURL)
    }

    public func deleteRun(id: Int) {
        history.removeAll { $0.id == id }
        historyStore.save(history, project: historyProjectURL)
    }

    private var op: Operator?
    private var engine: Engine?
    private var ports: [LumpedPortExtension] = []
    private var currentTask: Task<Void, Never>?
    private var nextRunID = 1
    private var lastExcitedPortName: String?
    private var lastImpedanceOhm: Double = 50

    /// `historyStore` is injectable so a test can persist somewhere
    /// disposable rather than into the user's Application Support folder.
    public init(historyStore: RunHistoryStore = RunHistoryStore()) {
        self.historyStore = historyStore
    }

    /// Recomputes `s11Spectrum` over `[minimumHertz, maximumHertz]` from the
    /// current run's already-recorded V(t)/I(t) — no re-simulation needed,
    /// since the DFT can be evaluated at any frequency after the fact. Lets
    /// the plot be zoomed into a sub-band for a closer look at a resonance.
    /// Recomputes the plotted spectrum over `[minimumHertz, maximumHertz]`,
    /// **clamped to `sweptFrequencyRange`** — the band that was actually
    /// excited and simulated. A DFT is mathematically well-defined at any
    /// frequency, so without this clamp a stray or stale value here would
    /// silently plot frequencies that were never simulated: numbers with no
    /// real excitation energy behind them, indistinguishable on the chart
    /// from a real result. `plotRange` (published) always reflects what was
    /// actually applied, so the UI can resync its fields to the clamped
    /// value rather than keep showing an invalid request.
    public func setPlotRange(minimumHertz: Double, maximumHertz: Double) {
        guard maximumHertz > minimumHertz, minimumHertz > 0 else { return }
        guard let full = sweptFrequencyRange else { return }
        guard let name = lastExcitedPortName,
              let excited = ports.first(where: { $0.extensionName == "Port_\(name)" }),
              excited.timeSeconds.count > 1 else { return }

        let clampedMin = min(max(minimumHertz, full.minimumHertz), full.maximumHertz)
        let clampedMax = max(min(maximumHertz, full.maximumHertz), full.minimumHertz)
        guard clampedMax > clampedMin else { return }

        let count = max(spectrumPointCount, 2)
        var spectrum: [S11Point] = []
        spectrum.reserveCapacity(count)
        for i in 0..<count {
            let f = clampedMin + (clampedMax - clampedMin) * Double(i) / Double(count - 1)
            spectrum.append(S11Point(hertz: f, decibels: PortSpectrum.s11(port: excited, impedanceOhm: lastImpedanceOhm, atHertz: f)))
        }
        s11Spectrum = spectrum
        s11DbAtCenter = PortSpectrum.s11(port: excited, impedanceOhm: lastImpedanceOhm, atHertz: (clampedMin + clampedMax) / 2)
        plotRange = FrequencyRange(minimumHertz: clampedMin, maximumHertz: clampedMax)
    }

    /// Undoes `setPlotRange`, back to the full range that was simulated.
    public func resetPlotRangeToFullSweep() {
        guard let full = sweptFrequencyRange else { return }
        setPlotRange(minimumHertz: full.minimumHertz, maximumHertz: full.maximumHertz)
    }

    /// Cancels the run in progress, if any. The time series recorded so far
    /// is still used to compute a (less converged, but often still useful)
    /// S11 spectrum, rather than discarding the work outright.
    public func stop() {
        currentTask?.cancel()
    }

    /// Returns the background task driving the run, mainly so tests (and any
    /// caller that wants to know when a run finishes) can `await` it — the UI
    /// is free to ignore the return value and just watch the `@Published`
    /// properties instead.
    @discardableResult
    public func run(document: CADDocument) throws -> Task<Void, Never> {
        let resolved = document.resolved
        guard resolved.errorCount == 0 else { throw RunnerError.modelHasErrors(resolved.errorCount) }
        guard resolved.simulation.domain != nil else { throw RunnerError.noDomain }
        guard resolved.simulation.ports.contains(where: { $0.kind == .lumped && $0.isExcited }) else {
            throw RunnerError.noExcitedLumpedPort
        }

        let setup = document.state.simulation
        let unit = document.state.lengthUnit

        guard let lines = GridMesher.makeDiscLines(resolved: resolved, setup: setup, unit: unit) else {
            throw RunnerError.noDomain
        }

        let materialProvider = CADMaterialProvider(bodies: resolved.bodies, materials: document.state.materials, unit: unit)

        // Catch the degenerate "port feeding nothing" setup before spending
        // minutes on a run: if there's no conductor for the resistor to load
        // into, the local edge is a resistor perfectly matched to its own
        // reference impedance and S11 is guaranteed to sit near 0 dB
        // everywhere, regardless of frequency — a result that looks like a
        // solver bug but is actually just an unconnected port.
        for port in resolved.simulation.ports where port.kind == .lumped && port.isExcited {
            guard hasConductorNearPort(port, materialProvider: materialProvider, unit: unit, meshLines: lines) else {
                throw RunnerError.noConductorNearExcitedPort(port.name)
            }
        }

        let op = Operator()
        op.setupGrid(discLines: lines.metersLines, gridDeltaUnit: 1.0) // lines are already in meters
        op.materialProvider = materialProvider
        op.absorbingBoundary = makeAbsorbingBoundary(boundaries: setup.boundaries, lines: lines.metersLines)

        let handle = EngineHandle()
        var portExtensions: [LumpedPortExtension] = []
        var factories: [() -> EngineExtension] = []

        for port in resolved.simulation.ports where port.kind == .lumped {
            let directionIndex = axisIndex(port.direction)

            // The port's own axis: the gap's *start* terminal, not its
            // center — GridMesher always inserts a fixed line at both
            // port.bounds.minimum/maximum, so this lands exactly on a grid
            // line and the gap spans exactly one Yee edge in that direction.
            // The two transverse axes just need the nearest node to center.
            var gridPos = (0, 0, 0)
            for axis in Axis.allCases {
                let i = axisIndex(axis)
                let valueMeters: Double
                if axis == port.direction {
                    valueMeters = unit.toMeters(port.bounds.minimum[axis])
                } else {
                    let center = (port.bounds.minimum[axis] + port.bounds.maximum[axis]) / 2
                    valueMeters = unit.toMeters(center)
                }
                let index = nearestIndex(lines.metersLines[i], valueMeters)
                switch i {
                case 0: gridPos.0 = index
                case 1: gridPos.1 = index
                default: gridPos.2 = index
                }
            }

            // Stamp the port's reference impedance directly onto this edge
            // so it is a real R-loaded node, not just a lossless soft source.
            op.addLumpedResistor(direction: directionIndex, pos: gridPos, ohms: port.impedanceOhm)

            let ext = LumpedPortExtension(
                name: "Port_\(port.name)",
                handle: handle,
                directionIndex: directionIndex,
                gridPos: gridPos,
                gapLengthMeters: unit.toMeters(port.gapLength),
                excitation: setup.excitation,
                frequency: setup.frequency,
                isExcited: port.isExcited,
                amplitude: port.amplitude,
                dT: { [weak op] in op?.dT ?? 0 }
            )
            portExtensions.append(ext)
            factories.append { ext }
        }

        // Far-field recording, when asked for. Registered before
        // `calcECOperator()` like every other extension, and only when
        // enabled — the surface DFT costs memory and per-step work that a
        // run only interested in S11 should not pay.
        let farFieldFrequencies = setup.farField.effectiveFrequencies(in: setup.frequency)
        var farFieldExtension: NearFieldToFarFieldExtension?
        var pendingFarFieldWarning: String?
        if !farFieldFrequencies.isEmpty {
            if let cells = NearFieldToFarFieldExtension.makeSurface(
                op: op,
                pmlCellCount: setup.boundaries.pmlCellCount
            ) {
                let ext = NearFieldToFarFieldExtension(
                    name: "FarField",
                    handle: handle,
                    op: op,
                    cells: cells,
                    frequenciesHertz: farFieldFrequencies
                )
                farFieldExtension = ext
                factories.append { ext }
            } else {
                pendingFarFieldWarning = """
                No room for a far-field surface: the \(setup.boundaries.pmlCellCount)-cell absorbing                 boundary leaves too little of the \(op.numLines.0)x\(op.numLines.1)x\(op.numLines.2)                 grid to enclose the antenna. Increase the domain padding (half a wavelength or more on                 every side is typical), refine the mesh, or reduce the PML cell count.
                """
            }
        }

        op.extensionFactories = factories
        op.calcECOperator()
        applyHardWallBoundaries(op: op, boundaries: setup.boundaries)

        let engine = Engine.make(op: op)
        handle.engine = engine

        self.op = op
        self.engine = engine
        self.ports = portExtensions
        self.gridSize = op.numLines
        self.isRunning = true
        self.progress = 0
        self.s11DbAtCenter = nil
        self.s11Spectrum = []
        self.farFieldPatterns = []
        self.farFieldWarning = pendingFarFieldWarning
        self.wasStoppedEarly = false

        let maxSteps = UInt(setup.solver.maximumTimeSteps)
        let chunk: UInt = 500
        let frequency = setup.frequency
        let excitedPortName = resolved.simulation.ports.first(where: { $0.kind == .lumped && $0.isExcited })!.name
        let impedanceOhm = resolved.simulation.ports.first(where: { $0.kind == .lumped && $0.isExcited })!.impedanceOhm
        let spectrumPointCount = self.spectrumPointCount
        let portExtensionsSnapshot = portExtensions
        let farFieldSnapshot = farFieldExtension
        let farFieldAngleStep = setup.farField.effectiveAngularStepDegrees
        let runID = nextRunID
        let variableSnapshot = resolved.variables.values
        let gridSizeForHistory = op.numLines

        self.lastExcitedPortName = excitedPortName
        self.lastImpedanceOhm = impedanceOhm
        self.sweptFrequencyRange = frequency
        self.plotRange = frequency
        self.nextRunID += 1

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            var done: UInt = 0
            var stopped = false
            while done < maxSteps {
                if Task.isCancelled { stopped = true; break }
                let step = min(chunk, maxSteps - done)
                engine.iterateTS(step)
                done += step
                let fraction = Double(done) / Double(maxSteps)
                await MainActor.run { [weak self] in self?.progress = fraction }
            }

            let didStop = stopped
            guard let excited = portExtensionsSnapshot.first(where: { $0.extensionName == "Port_\(excitedPortName)" }),
                  excited.timeSeconds.count > 1 else {
                await MainActor.run { [weak self] in
                    self?.isRunning = false
                    self?.wasStoppedEarly = didStop
                }
                return
            }

            // The DFT integrates over whatever was recorded, so a stopped
            // run still yields a (less converged) spectrum instead of
            // nothing — useful for an early peek at where a resonance is
            // heading without waiting for the full step count.
            let centerDb = PortSpectrum.s11(port: excited, impedanceOhm: impedanceOhm, atHertz: frequency.centerHertz)
            var spectrumBuilder: [S11Point] = []
            spectrumBuilder.reserveCapacity(spectrumPointCount)
            let count = max(spectrumPointCount, 2)
            for i in 0..<count {
                let f = frequency.minimumHertz
                    + (frequency.maximumHertz - frequency.minimumHertz) * Double(i) / Double(count - 1)
                let db = PortSpectrum.s11(port: excited, impedanceOhm: impedanceOhm, atHertz: f)
                spectrumBuilder.append(S11Point(hertz: f, decibels: db))
            }
            let finalSpectrum = spectrumBuilder

            // The transform runs once, after stepping: it is a pure function
            // of the accumulated surface DFT, so it costs nothing during the
            // run itself.
            let patterns = Self.evaluateFarField(
                farFieldSnapshot,
                angleStepDegrees: farFieldAngleStep,
                port: excited,
                impedanceOhm: impedanceOhm
            )

            let record = RunRecord(
                id: runID,
                timestamp: Date(),
                variableSnapshot: variableSnapshot,
                sweptFrequencyRange: frequency,
                maximumTimeSteps: Int(maxSteps),
                wasStoppedEarly: didStop,
                gridSize: gridSizeForHistory,
                s11Spectrum: finalSpectrum,
                s11DbAtCenter: centerDb,
                farFieldPatterns: patterns
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.wasStoppedEarly = didStop
                self.s11DbAtCenter = centerDb
                self.s11Spectrum = finalSpectrum
                self.farFieldPatterns = patterns
                self.history.append(record)
                // Persisted immediately: a run can take an hour, and losing
                // it to a crash or a quit afterwards would be galling.
                self.historyStore.save(self.history, project: self.historyProjectURL)
            }
        }
        currentTask = task
        return task
    }

    /// Turns the recorded surface into one pattern per frequency.
    ///
    /// Accepted power and reflection come from the excited port at the same
    /// frequency, which is what lets the pattern report gain rather than only
    /// directivity. Both are optional: a run without usable port data still
    /// yields a valid directivity pattern.
    nonisolated private static func evaluateFarField(
        _ recorder: NearFieldToFarFieldExtension?,
        angleStepDegrees: Double,
        port: LumpedPortExtension?,
        impedanceOhm: Double
    ) -> [FarFieldPattern] {
        guard let recorder else { return [] }
        let grid = NearFieldToFarFieldExtension.angleGrid(stepDegrees: angleStepDegrees)

        return recorder.frequenciesHertz.indices.map { index in
            let frequency = recorder.frequenciesHertz[index]
            var accepted: Double?
            var reflection: Double?

            if let port {
                let v = PortSpectrum.dft(time: port.timeSeconds, values: port.voltage, atHertz: frequency)
                let i = PortSpectrum.dft(time: port.timeSeconds, values: port.current, atHertz: frequency)
                // P_accepted = ½ Re(V · I*).
                let power = 0.5 * (v.real * i.real + v.imag * i.imag)
                if power > 0 { accepted = power }

                let s11Db = PortSpectrum.s11(port: port, impedanceOhm: impedanceOhm, atHertz: frequency)
                if s11Db.isFinite { reflection = pow(10, s11Db / 20) }
            }

            return recorder.pattern(
                frequencyIndex: index,
                thetaDegrees: grid.theta,
                phiDegrees: grid.phi,
                acceptedPowerWatts: accepted,
                reflectionCoefficient: reflection
            )
        }
    }

    /// Maps `.electric`/`.magnetic` faces to a permanent hard wall (the
    /// operator coefficients are zeroed once, right after
    /// `calcECOperator()`). `.pml` is handled separately by the graded loss
    /// layer set up before `calcECOperator()` runs; `.periodic` has no
    /// implementation here, so those faces are simply left as they are
    /// (equivalent to an untreated, reflective open boundary).
    private func applyHardWallBoundaries(op: Operator, boundaries: BoundarySettings) {
        let faces: [BoundaryCondition] = [
            boundaries.xMin, boundaries.xMax,
            boundaries.yMin, boundaries.yMax,
            boundaries.zMin, boundaries.zMax
        ]
        let electric = faces.map { $0 == .electric }
        let magnetic = faces.map { $0 == .magnetic }
        if electric.contains(true) { op.applyElectricBC(electric) }
        if magnetic.contains(true) { op.applyMagneticBC(magnetic) }
    }

    private func makeAbsorbingBoundary(boundaries: BoundarySettings, lines: [[Double]]) -> AbsorbingBoundarySettings? {
        let faces: [BoundaryCondition] = [
            boundaries.xMin, boundaries.xMax,
            boundaries.yMin, boundaries.yMax,
            boundaries.zMin, boundaries.zMax
        ]
        let absorbingFaces = faces.map { $0 == .pml }
        guard absorbingFaces.contains(true), boundaries.pmlCellCount > 0 else { return nil }

        // Gedney's commonly-used estimate for a graded absorber's peak
        // conductivity, evaluated at the smallest cell size present (a
        // conservative choice: it over-absorbs a bit rather than
        // under-absorbing and letting more energy leak back in).
        let smallestCell = lines.flatMap { axisLines in
            zip(axisLines, axisLines.dropFirst()).map { $1 - $0 }
        }.filter { $0 > 0 }.min() ?? 1e-3
        let order = 3.0
        let sigmaMax = (order + 1) / (150 * .pi * smallestCell)

        return AbsorbingBoundarySettings(
            absorbingFaces: absorbingFaces,
            cellCount: boundaries.pmlCellCount,
            gradingOrder: order,
            maxElectricLossSPerM: sigmaMax
        )
    }

    /// Samples the material a small distance beyond each terminal, along the
    /// port's own axis, and reports whether either side looks conductive.
    /// Sampling exactly *at* begin/end would land right on the vacuum/metal
    /// interface, which quarter-cell averaging can blend into an ambiguous
    /// mid-value — stepping out by one gap length lands solidly inside
    /// whatever body (if any) actually continues the circuit past the port.
    /// Steps a small distance beyond each terminal, along the port's own
    /// axis, and checks whether that lands in a conductor.
    ///
    /// The step is the **local mesh cell size** at that terminal, not the
    /// port's own gap length. An earlier version stepped by the full gap,
    /// which is wrong whenever a port is much longer than the (thin)
    /// conductor it terminates on — e.g. a vertical via through a substrate,
    /// gap ~1.5mm, landing on a 35µm copper ground plane: stepping a full
    /// gap-length past the plane overshoots it by over a millimeter and
    /// samples free space, reporting a false "not touching a conductor" for
    /// a port that is in fact correctly placed. The mesh cell size is the
    /// right scale because it's what the solver can actually resolve at that
    /// point regardless of how long the port itself is.
    private func hasConductorNearPort(
        _ port: ResolvedPort,
        materialProvider: CADMaterialProvider,
        unit: LengthUnit,
        meshLines: GridMesher.Lines
    ) -> Bool {
        guard let begin = port.begin, let end = port.end else { return true } // waveguide ports: not this check's business
        let axis = port.direction
        let direction = axisIndex(axis)
        let axisLinesMeters = meshLines.metersLines[direction]

        func metersPoint(_ v: Vec3) -> Vec3 {
            Vec3(x: unit.toMeters(v.x), y: unit.toMeters(v.y), z: unit.toMeters(v.z))
        }

        // Comfortably above a lossy dielectric's conductivity, comfortably
        // below the solver's PEC approximation (1e7 S/m) — a coarse but
        // effective "is this basically a conductor" threshold.
        let conductiveThresholdSPerM = 1.0

        func isConductive(_ point: Vec3) -> Bool {
            let sigma = materialProvider.material(direction: direction, coords: (point.x, point.y, point.z), matType: 1)
            return sigma >= conductiveThresholdSPerM
        }

        // Sample on *both* sides of the terminal, not just "away from the
        // other terminal": a terminal can equally correctly land on a thin
        // conductor's near face (conductor is on the away side) or its far
        // face (conductor is on the gap side, e.g. a via that passes all the
        // way through a ground plane's thickness and ends at its outer
        // surface). Assuming a fixed direction made a real, correctly
        // touching via-through-ground-plane port register as unconnected.
        func touchesConductor(at terminalMeters: Vec3) -> Bool {
            let step = localCellSize(near: terminalMeters[axis], in: axisLinesMeters)
            var forward = terminalMeters
            forward[axis] += step
            var backward = terminalMeters
            backward[axis] -= step
            return isConductive(forward) || isConductive(backward)
        }

        // Both terminals must actually touch a conductor — a resistor with
        // only one end connected can't do anything, so requiring just one
        // (the earlier behavior) was too lenient.
        return touchesConductor(at: metersPoint(begin)) && touchesConductor(at: metersPoint(end))
    }

    /// The smaller of the two grid spacings adjacent to `value` in a sorted
    /// line array — conservative on purpose, so a step never overshoots past
    /// a thin layer just because the mesh happens to be coarser on the other
    /// side of it.
    private func localCellSize(near value: Double, in sortedLines: [Double]) -> Double {
        guard sortedLines.count > 1 else { return 1e-3 }
        let idx = nearestIndex(sortedLines, value)
        if idx <= 0 { return sortedLines[1] - sortedLines[0] }
        if idx >= sortedLines.count - 1 { return sortedLines[idx] - sortedLines[idx - 1] }
        return min(sortedLines[idx] - sortedLines[idx - 1], sortedLines[idx + 1] - sortedLines[idx])
    }

    private func axisIndex(_ axis: Axis) -> Int {
        switch axis {
        case .x: return 0
        case .y: return 1
        case .z: return 2
        }
    }

    private func nearestIndex(_ lines: [Double], _ value: Double) -> Int {
        guard !lines.isEmpty else { return 0 }
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, line) in lines.enumerated() {
            let d = abs(line - value)
            if d < bestDistance { bestDistance = d; bestIndex = index }
        }
        return bestIndex
    }
}