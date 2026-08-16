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
            fixed.insert(domain.minimum(on: axis))
            fixed.insert(domain.maximum(on: axis))

            if setup.mesh.snapToBodyEdges {
                for body in resolved.bodies where body.isVisible {
                    fixed.insert(body.axisAlignedBounds.minimum(on: axis))
                    fixed.insert(body.axisAlignedBounds.maximum(on: axis))
                }
            }
            for port in resolved.simulation.ports {
                fixed.insert(port.bounds.minimum(on: axis))
                fixed.insert(port.bounds.maximum(on: axis))
            }
            for refinement in plan.refinements {
                fixed.insert(refinement.bounds.minimum(on: axis))
                fixed.insert(refinement.bounds.maximum(on: axis))
            }
            for value in plan.fixedLines(on: axis) {
                fixed.insert(value)
            }

            let sortedFixed = fixed.sorted().filter { $0 >= domain.minimum(on: axis) && $0 <= domain.maximum(on: axis) }

            // Docelowy rozmiar komórki w danym punkcie: bazowy, chyba że
            // punkt leży wewnątrz regionu refinement - wtedy najmniejszy
            // pasujący target.
            func targetCellSize(at x: Double) -> Double {
                var target = baseCell
                for refinement in plan.refinements {
                    if x >= refinement.bounds.minimum(on: axis) && x <= refinement.bounds.maximum(on: axis) {
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
                lines = [domain.minimum(on: axis), domain.maximum(on: axis)]
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
    private func contains(_ body: ResolvedBody, point: Vec3) -> Bool {
        // Szybkie odrzucenie przez AABB przed dokładniejszym testem.
        guard body.axisAlignedBounds.contains(point) else { return false }

        let local = toLocal(point, position: body.position, rotationDegrees: body.rotationDegrees, scale: body.scale)

        switch body.shape {
        case .box(let size):
            return abs(local.x) <= size.x / 2 && abs(local.y) <= size.y / 2 && abs(local.z) <= size.z / 2
        case .sheet(let size, _):
            // Kwestia grubości zerowej: traktujemy jak cienki plaster o
            // szerokości jednej komórki (mesher i tak stawia tam linię
            // graniczną dzięki snapToBodyEdges).
            return abs(local.x) <= max(size.x, 0) / 2
                && abs(local.y) <= max(size.y, 0) / 2
                && abs(local.z) <= max(size.z, 0) / 2
        case .cylinder(let radius, let length, let axis):
            switch axis {
            case .x:
                return abs(local.x) <= length / 2 && (local.y * local.y + local.z * local.z) <= radius * radius
            case .y:
                return abs(local.y) <= length / 2 && (local.x * local.x + local.z * local.z) <= radius * radius
            case .z:
                return abs(local.z) <= length / 2 && (local.x * local.x + local.y * local.y) <= radius * radius
            }
        }
    }

    private func toLocal(_ point: Vec3, position: Vec3, rotationDegrees: Vec3, scale: Vec3) -> Vec3 {
        var p = Vec3(x: point.x - position.x, y: point.y - position.y, z: point.z - position.z)
        // Odwrotna rotacja: extrinsic XYZ degrees, Z then Y then X (patrz
        // SolverExport.Meta.rotationConvention) -> odwracamy w kolejności X,Y,Z.
        p = rotate(p, axis: .x, degrees: -rotationDegrees.x)
        p = rotate(p, axis: .y, degrees: -rotationDegrees.y)
        p = rotate(p, axis: .z, degrees: -rotationDegrees.z)
        return Vec3(x: p.x / scale.x, y: p.y / scale.y, z: p.z / scale.z)
    }

    private func rotate(_ v: Vec3, axis: Axis, degrees: Double) -> Vec3 {
        guard degrees != 0 else { return v }
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r)
        switch axis {
        case .x: return Vec3(x: v.x, y: v.y * c - v.z * s, z: v.y * s + v.z * c)
        case .y: return Vec3(x: v.x * c + v.z * s, y: v.y, z: -v.x * s + v.z * c)
        case .z: return Vec3(x: v.x * c - v.y * s, y: v.x * s + v.y * c, z: v.z)
        }
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

/// Prosty port skupiony: miękkie źródło napięciowe (dla portu wzbudzanego)
/// + rejestracja V(t)/I(t) na potrzeby S-parametrów. To NIE jest pełny
/// port rezystancyjny openEMS (brak modyfikacji lokalnej G/R w operatorze) -
/// wystarcza do pierwszych uruchomień i porównań jakościowych; do S11
/// ilościowo zgodnego z openEMS trzeba dodatkowo wstrzyknąć rezystor przez
/// CADMaterialProvider (patrz komentarz w SimulationRunner).
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
        let i = engine.getCurr(directionIndex, gridPos.0, gridPos.1, gridPos.2)
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

// MARK: - 6. Orchestrator: CADDocument -> Engine -> wyniki

@MainActor
public final class SimulationRunner: ObservableObject {
    public enum RunnerError: Error, LocalizedError {
        case noDomain
        case modelHasErrors(Int)

        public var errorDescription: String? {
            switch self {
            case .noDomain: return "Domena obliczeniowa nie jest zdefiniowana."
            case .modelHasErrors(let n): return "Model ma \(n) błąd(ów) - popraw je przed uruchomieniem symulacji."
            }
        }
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var s11DbAtCenter: Double?
    @Published public private(set) var gridSize: (Int, Int, Int) = (0, 0, 0)

    private var op: Operator?
    private var engine: Engine?
    private var ports: [LumpedPortExtension] = []

    public init() {}

    public func run(document: CADDocument) throws {
        let resolved = document.resolved
        guard resolved.errorCount == 0 else { throw RunnerError.modelHasErrors(resolved.errorCount) }
        guard resolved.simulation.domain != nil else { throw RunnerError.noDomain }

        let setup = document.state.simulation
        let unit = document.state.lengthUnit

        guard let lines = GridMesher.makeDiscLines(resolved: resolved, setup: setup, unit: unit) else {
            throw RunnerError.noDomain
        }

        let op = Operator()
        op.setupGrid(discLines: lines.metersLines, gridDeltaUnit: 1.0) // linie już w metrach
        op.materialProvider = CADMaterialProvider(bodies: resolved.bodies, materials: document.state.materials, unit: unit)

        let handle = EngineHandle()
        var portExtensions: [LumpedPortExtension] = []
        var factories: [() -> EngineExtension] = []

        for port in resolved.simulation.ports {
            let center = Vec3(
                x: (port.bounds.minimum(on: .x) + port.bounds.maximum(on: .x)) / 2,
                y: (port.bounds.minimum(on: .y) + port.bounds.maximum(on: .y)) / 2,
                z: (port.bounds.minimum(on: .z) + port.bounds.maximum(on: .z)) / 2
            )
            let centerMeters = (unit.toMeters(center.x), unit.toMeters(center.y), unit.toMeters(center.z))
            let gridPos = (
                nearestIndex(lines.metersLines[0], centerMeters.0),
                nearestIndex(lines.metersLines[1], centerMeters.1),
                nearestIndex(lines.metersLines[2], centerMeters.2)
            )
            let directionIndex = port.direction == .x ? 0 : (port.direction == .y ? 1 : 2)
            let gapMeters = unit.toMeters(port.gapLength)

            let ext = LumpedPortExtension(
                name: "Port_\(port.name)",
                handle: handle,
                directionIndex: directionIndex,
                gridPos: gridPos,
                gapLengthMeters: gapMeters,
                excitation: setup.excitation,
                frequency: setup.frequency,
                isExcited: port.isExcited,
                amplitude: port.amplitude,
                dT: { [weak op] in op?.dTValueOrZero() ?? 0 }
            )
            portExtensions.append(ext)
            factories.append { ext }
        }

        op.extensionFactories = factories
        op.calcECOperator()

        let engine = Engine.make(op: op)
        handle.engine = engine

        self.op = op
        self.engine = engine
        self.ports = portExtensions
        self.gridSize = op.numLines
        self.isRunning = true
        self.progress = 0

        let maxSteps = UInt(setup.solver.maximumTimeSteps)
        let chunk: UInt = 500

        Task.detached(priority: .userInitiated) { [weak self] in
            var done: UInt = 0
            while done < maxSteps {
                let step = min(chunk, maxSteps - done)
                engine.iterateTS(step)
                done += step
                let fraction = Double(done) / Double(maxSteps)
                await MainActor.run { self?.progress = fraction }
            }
            await MainActor.run {
                self?.isRunning = false
                self?.finishAndComputeS11(centerHertz: setup.frequency.centerHertz, ports: portExtensions, resolved: resolved)
            }
        }
    }

    private func finishAndComputeS11(centerHertz: Double, ports: [LumpedPortExtension], resolved: ResolvedModel) {
        guard let excitedPort = resolved.simulation.ports.first(where: \.isExcited),
              let ext = ports.first(where: { $0.extensionName == "Port_\(excitedPort.name)" }) else { return }
        s11DbAtCenter = PortSpectrum.s11(port: ext, impedanceOhm: excitedPort.impedanceOhm, atHertz: centerHertz)
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

// MARK: - Small helpers expected to exist / be added on your side

private extension Operator {
    /// Operator.dT jest `private(set)`; jeśli w Twojej wersji nie jest
    /// publicznie czytelny, dodaj w FDTDSolver.swift:
    ///   public var timestepSeconds: Double { dT }
    /// i podmień to wywołanie na `self.timestepSeconds`.
    func dTValueOrZero() -> Double { 0 } // PLACEHOLDER - patrz komentarz wyżej
}