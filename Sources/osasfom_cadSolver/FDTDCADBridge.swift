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

            // Coalesce fixed lines that are the same coordinate to within
            // rounding. Two bodies sharing a face routinely disagree in the
            // last bit — a substrate's top at 1.575 and the patch's bottom at
            // 1.575 arrive via different arithmetic — which leaves a
            // zero-width interval between them. Uniform fill shrugged that
            // off; a geometric ramp seeded from a 1e-16 "cell" does not.
            let withinDomain = fixed.sorted().filter { $0 >= domain.minimum[axis] && $0 <= domain.maximum[axis] }
            var sortedFixed: [Double] = []
            for value in withinDomain {
                if let last = sortedFixed.last, value - last < minCell * 1e-3 { continue }
                sortedFixed.append(value)
            }

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

            // Each interval's own target first, so a fill can see how fine its
            // neighbours are and ramp toward them instead of stepping.
            let intervalCount = max(sortedFixed.count - 1, 0)
            let targets = (0..<intervalCount).map { i in
                targetCellSize(at: (sortedFixed[i] + sortedFixed[i + 1]) / 2)
            }

            // What a neighbour would *actually* use, which is not its target:
            // an interval shorter than its target gets one cell the width of
            // the interval. That is where the fine cells in a board come from
            // — a 0.4 mm substrate layer pinned between two fixed lines, with
            // a 3.5 mm target — so grading against targets alone would ramp
            // toward nothing and leave the step in place.
            let uniformCell = (0..<intervalCount).map { i -> Double in
                let length = sortedFixed[i + 1] - sortedFixed[i]
                let count = max(1, Int((length / targets[i]).rounded()))
                return length / Double(count)
            }

            var lines: [Double] = []
            for i in 0..<intervalCount {
                lines.append(contentsOf: fillInterval(
                    a: sortedFixed[i],
                    b: sortedFixed[i + 1],
                    target: targets[i],
                    startCell: i > 0 ? uniformCell[i - 1] : uniformCell[i],
                    endCell: i + 1 < intervalCount ? uniformCell[i + 1] : uniformCell[i],
                    growth: growth,
                    minimum: minCell
                ))
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

    /// Fills `[a, b)` with lines that reach `target` in the middle while
    /// ramping geometrically toward whatever the neighbouring intervals use.
    ///
    /// `maxGrowthRatio` used to be accepted, stored, written into the solver
    /// deck and then discarded — every interval was divided uniformly, so cell
    /// size stepped abruptly at each fixed line. A board could go from 0.4 mm
    /// inside its substrate to 3.5 mm one cell later. That is a numerical
    /// discontinuity in its own right, and it is what the Yee coefficients are
    /// least forgiving of.
    ///
    /// `a` is included and `b` is not, so consecutive intervals join without
    /// duplicating a fixed line — and the fixed lines themselves never move,
    /// because the cell sizes are normalised to fill the span exactly.
    private static func fillInterval(
        a: Double,
        b: Double,
        target: Double,
        startCell: Double,
        endCell: Double,
        growth: Double,
        minimum: Double
    ) -> [Double] {
        guard b > a, target > 0 else { return [a] }
        let length = b - a
        let sizes = gradedCellSizes(
            length: length,
            target: target,
            startCell: startCell,
            endCell: endCell,
            growth: growth,
            minimum: minimum
        )

        var lines: [Double] = []
        lines.reserveCapacity(sizes.count)
        var x = a
        for size in sizes.dropLast() {
            lines.append(x)
            x += size
        }
        lines.append(x)
        return lines
    }

    /// Cell sizes spanning `length`: a geometric ramp up from each end's
    /// neighbour, `target` across the middle, normalised to fit exactly.
    static func gradedCellSizes(
        length: Double,
        target: Double,
        startCell: Double,
        endCell: Double,
        growth: Double,
        minimum: Double = 0
    ) -> [Double] {
        let maxReasonableCells = 20_000
        guard length > 0, target > 0 else { return [] }

        func uniform() -> [Double] {
            let count = min(max(1, Int((length / target).rounded())), maxReasonableCells)
            return Array(repeating: length / Double(count), count: count)
        }

        let ratio = max(growth, 1.0)
        guard ratio > 1.0000001 else { return uniform() }

        /// Sizes stepping up from a finer neighbour toward `target`. Empty
        /// when the neighbour is already as coarse — nothing to ramp.
        func ramp(from neighbour: Double) -> [Double] {
            guard neighbour > 0, neighbour < target else { return [] }
            var sizes: [Double] = []
            var size = neighbour * ratio
            while size < target, sizes.count < maxReasonableCells {
                sizes.append(size)
                size *= ratio
            }
            return sizes
        }

        // Floored at `minCellSize`: a ramp is only ever meant to bridge two
        // real cell sizes, never to chase a degenerate one down toward zero.
        let floor = Swift.max(minimum, 0)
        var head = ramp(from: Swift.max(Swift.min(startCell, target), floor))
        var tail = Array(ramp(from: Swift.max(Swift.min(endCell, target), floor)).reversed())

        // A short interval cannot hold both ramps; drop from the longer one
        // until they fit, so the finer end keeps its grading.
        while head.reduce(0, +) + tail.reduce(0, +) > length, !(head.isEmpty && tail.isEmpty) {
            if head.count >= tail.count, !head.isEmpty {
                head.removeLast()
            } else if !tail.isEmpty {
                tail.removeFirst()
            }
        }

        let remaining = length - head.reduce(0, +) - tail.reduce(0, +)
        let middle = remaining > 0 ? max(Int((remaining / target).rounded()), 0) : 0
        let sizes = head + Array(repeating: target, count: middle) + tail
        if sizes.isEmpty { return uniform() }
        if sizes.count > maxReasonableCells { return uniform() }

        // The fixed lines are boundaries the mesher promised to land on, so
        // the sizes are scaled to span the interval exactly rather than
        // letting rounding drift the far end.
        let total = sizes.reduce(0, +)
        guard total > 0 else { return uniform() }
        return sizes.map { $0 * length / total }
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


// MARK: - 2b. Zero-thickness conductors

/// Maps infinitely thin perfect conductors onto the Yee edges they occupy.
///
/// A sheet with no thickness is drawn by the viewport, snapped to by the
/// mesher, and *invisible to the solver*: `calcEffMatPos` averages material
/// over cell volumes, and a surface has none. Probing the material at a patch
/// drawn this way gives σ = 1e7 exactly on the plane and 0 one nanometre off
/// it, while the quarter-cell sampler only ever asks at quarter-cell offsets —
/// so the conductor contributed nothing and a patch antenna fed against one
/// reflected everything, flat across the band.
///
/// The fix is the standard one: stop treating it as a material and impose the
/// boundary condition. Tangential E vanishes on a perfect conductor, so every
/// edge lying in the sheet's plane and inside its outline is forced to zero.
public enum ZeroThicknessConductors {

    /// Edges to force, for every visible body that is a zero-thickness sheet
    /// of a material that conducts like a perfect conductor up to
    /// `maximumHertz` — PEC itself, or a metal such as copper.
    ///
    /// Only PEC used to qualify. A sheet assigned Copper, the natural choice
    /// for PCB metal, got no edges and had no volume for the material path to
    /// find, so it dropped out of the simulation without a word — while the
    /// port connectivity check, which samples exactly on the sheet, still
    /// passed. A zero-thickness sheet of anything that is not a good conductor
    /// really has nothing to contribute, and `warnings` says so.
    ///
    /// Rotated sheets are skipped: a plane at an angle does not lie along Yee
    /// edges, and staircasing it silently would be worse than leaving it to
    /// the (unchanged, still volumetric) material path. `warnings` names any
    /// that were skipped so the caller can surface them.
    public static func edges(
        bodies: [ResolvedBody],
        materials: [MaterialDefinition],
        unit: LengthUnit,
        lines: GridMesher.Lines,
        maximumHertz: Double,
        warnings: inout [String]
    ) -> [(direction: Int, pos: (Int, Int, Int))] {
        let byID = Dictionary(materials.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [(direction: Int, pos: (Int, Int, Int))] = []

        for body in bodies where body.isVisible {
            guard case .sheet(let size, let normal) = body.shape, size[normal] == 0 else { continue }
            guard let material = byID[body.materialID] else { continue }

            guard material.actsAsPerfectElectricConductor(upToHertz: maximumHertz) else {
                if let reason = unsupportedSheetReason(material) {
                    warnings.append("“\(body.name)” is a zero-thickness sheet of “\(material.name)”, \(reason)")
                }
                continue
            }

            guard body.isAxisAligned else {
                warnings.append(
                    "“\(body.name)” is a zero-thickness sheet that has been rotated. A tilted surface does not "
                        + "lie along grid edges, so it is not simulated as a conductor. Give it a thickness, or "
                        + "align it with an axis."
                )
                continue
            }

            let bounds = body.axisAlignedBounds
            let normalIndex = axisIndex(normal)
            let planeLines = lines.metersLines[normalIndex]
            let planeIndex = nearestIndex(planeLines, unit.toMeters(bounds.minimum[normal]))

            // The two in-plane axes carry the tangential field.
            let (first, second) = normal.perpendicular
            let firstIndex = axisIndex(first), secondIndex = axisIndex(second)
            let firstLines = lines.metersLines[firstIndex]
            let secondLines = lines.metersLines[secondIndex]

            let firstLow = nearestIndex(firstLines, unit.toMeters(bounds.minimum[first]))
            let firstHigh = nearestIndex(firstLines, unit.toMeters(bounds.maximum[first]))
            let secondLow = nearestIndex(secondLines, unit.toMeters(bounds.minimum[second]))
            let secondHigh = nearestIndex(secondLines, unit.toMeters(bounds.maximum[second]))
            guard firstHigh > firstLow, secondHigh > secondLow else {
                warnings.append(
                    "“\(body.name)” is smaller than one mesh cell, so it covers no grid edges and is not "
                        + "simulated. Refine the mesh around it, or give it a size the mesh can resolve."
                )
                continue
            }

            func position(_ a: Int, _ b: Int) -> (Int, Int, Int) {
                var pos = (0, 0, 0)
                switch normalIndex {
                case 0: pos.0 = planeIndex
                case 1: pos.1 = planeIndex
                default: pos.2 = planeIndex
                }
                switch firstIndex {
                case 0: pos.0 = a
                case 1: pos.1 = a
                default: pos.2 = a
                }
                switch secondIndex {
                case 0: pos.0 = b
                case 1: pos.1 = b
                default: pos.2 = b
                }
                return pos
            }

            // An edge belongs to the sheet when it lies inside the outline.
            // Edge `i` spans node i to i+1, so the along-axis index stops one
            // short while the transverse one includes the far boundary.
            for a in firstLow..<firstHigh {
                for b in secondLow...secondHigh {
                    result.append((direction: firstIndex, pos: position(a, b)))
                }
            }
            for a in firstLow...firstHigh {
                for b in secondLow..<secondHigh {
                    result.append((direction: secondIndex, pos: position(a, b)))
                }
            }
        }
        return result
    }

    /// Why a zero-thickness sheet of `material` is left out of the simulation,
    /// worded to follow the material's name — or `nil` when leaving it out
    /// changes nothing, as for a sheet of plain vacuum.
    private static func unsupportedSheetReason(_ material: MaterialDefinition) -> String? {
        switch material.kind {
        case .perfectElectricConductor:
            return nil
        case .perfectMagneticConductor:
            return "a magnetic conductor. Only electric conductors can be imposed on a surface, so it is not simulated."
        case .dielectric:
            let isVacuum = material.epsilonR == 1 && material.muR == 1
                && material.electricConductivity == 0 && material.magneticConductivity == 0
                && material.dispersion.isNone
            guard !isVacuum else { return nil }
            return "which is not a conductor across the simulated band. A surface has no volume for a dielectric "
                + "or lossy material to fill, so it is not simulated. Give it a thickness, or assign a metal."
        }
    }
}

// MARK: - 3. Excitation waveform (Gaussian pulse / sinusoidal / step)

public enum ExcitationWaveformSampler {
    /// How long the source keeps injecting, in seconds, or `nil` for one that
    /// never stops.
    ///
    /// The end criterion must not fire while the source is still driving: at
    /// t = 0 the domain holds no energy at all, so a decay test taken then
    /// would end the run before it began. Only a pulse has an end; a
    /// sinusoidal or step source pumps the domain indefinitely, its energy
    /// plateaus instead of decaying, and the run is meant to fall back on the
    /// step cap.
    public static func excitationDurationSeconds(
        excitation: Excitation,
        frequency: FrequencyRange
    ) -> Double? {
        switch excitation.waveform {
        case .sinusoidal, .step:
            return nil
        case .gaussianPulse:
            // Matches `value(excitation:frequency:timeSeconds:)`, which
            // centres the pulse at t0 = 3σ. Five more σ puts the Gaussian
            // envelope at exp(-12.5) ≈ 4e-6 of peak — genuinely spent. The
            // obvious 2·t0 = 6σ is not: it leaves the source still at ~1% of
            // peak, which is well above the -40 dB the criterion is watching
            // for and would have it test a domain that is still being driven.
            let fCenter = frequency.centerHertz
            let bw = max(frequency.bandwidthHertz, fCenter * 0.05)
            let sigma = 1 / (Double.pi * bw)
            return 8 * sigma
        }
    }

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

// MARK: - 4. Ports as EngineExtensions

/// Anything that records a port's time series for the S-parameter DFT.
///
/// Exists so post-processing does not care which kind of port produced the
/// waveforms. The one thing the two kinds genuinely disagree about is the
/// reference impedance: a lumped port has a fixed one the user typed, while a
/// waveguide mode's wave impedance is *dispersive* — it rises without bound as
/// the frequency approaches cutoff and does not exist below it. Hence a
/// function of frequency, and one that is allowed to refuse.
public protocol PortRecorder: AnyObject {
    var extensionName: String { get }
    var timeSeconds: [Double] { get }
    /// Modal voltage for a lumped port; modal transverse-E amplitude for a
    /// waveguide. Either way, the quantity that pairs with `current` through
    /// `referenceImpedance`.
    var voltage: [Double] { get }
    var current: [Double] { get }
    func referenceImpedance(atHertz hertz: Double) -> Double?
}

// MARK: - 4a. Lumped port

/// Uchwyt przekazywany do rozszerzeń, bo w chwili tworzenia (Operator.
/// extensionFactories) obiekt Engine jeszcze nie istnieje - Engine
/// przypisuje się do handle zaraz po Engine.make(op:).
public final class EngineHandle {
    public weak var engine: Engine?
    public init() {}
}

/// A resistively-terminated lumped port: `Operator.addLumpedResistor` stamps
/// the port's reference impedance directly onto the gap edges' conductance
/// (so they are no longer lossless material cells but actual R-loaded
/// nodes), and this extension adds the Thevenin source voltage on top each
/// step and records V(t)/I(t) for the S-parameter DFT. This is the same
/// two-part scheme openEMS uses for a lumped-port excitation (soft voltage
/// injection at a resistively-stamped edge), not a full openEMS
/// `Operator_Ext_LumpedElement` port — port current is read from the
/// adjacent H-field (`Engine.getCurr`) as a proxy for the true Ampere's-law
/// loop current.
///
/// The gap is a *chain* of Yee edges, not one edge. `GridMesher` pins a line
/// at both terminals but keeps filling in between them, so an 8 mm gap on a
/// 3 mm mesh is three cells. Those edges are in series: each carries its own
/// share of the reference impedance and of the source voltage, and the port
/// voltage is their sum — the line integral over the whole gap. Loading only
/// the first edge (what this did before) left the resistor and the generator
/// pressed against one terminal with bare vacuum across the rest of the gap,
/// and measured V over a fraction of the integration path, so Zin and S11
/// came out wrong by roughly that fraction.
public final class LumpedPortExtension: EngineExtension, PortRecorder {
    /// One Yee edge of the gap, and the fraction of the gap length it spans.
    /// Shares sum to 1 across a port.
    public struct Edge {
        public let pos: (Int, Int, Int)
        public let share: Double

        public init(pos: (Int, Int, Int), share: Double) {
            self.pos = pos
            self.share = share
        }
    }

    public let priority = 100
    public let extensionName: String

    private let handle: EngineHandle
    private let directionIndex: Int
    private let edges: [Edge]
    /// The reference impedance stamped across the gap. Frequency-independent,
    /// unlike a waveguide mode's.
    private let impedanceOhm: Double
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
        edges: [Edge],
        impedanceOhm: Double,
        excitation: Excitation,
        frequency: FrequencyRange,
        isExcited: Bool,
        amplitude: Double,
        dT: @escaping () -> Double
    ) {
        self.extensionName = name
        self.handle = handle
        self.directionIndex = directionIndex
        self.edges = edges
        self.impedanceOhm = impedanceOhm
        self.excitation = excitation
        self.frequency = frequency
        self.isExcited = isExcited
        self.amplitude = amplitude
        self.dT = dT
    }

    public func doPreVoltageUpdates() {}
    public func doPostVoltageUpdates() {}

    public func apply2Voltages() {
        guard let engine = handle.engine, !edges.isEmpty else { return }
        let t = Double(engine.numTS) * dT()

        if isExcited {
            let waveform = ExcitationWaveformSampler.value(excitation: excitation, frequency: frequency, timeSeconds: t)
            let injected = amplitude * waveform
            // One generator sits in the gap, so its voltage divides across
            // the series edges by length. Summing the edges below hands back
            // exactly the amplitude that was asked for.
            for edge in edges {
                let existing = engine.getVolt(directionIndex, edge.pos.0, edge.pos.1, edge.pos.2)
                engine.setVolt(
                    directionIndex,
                    edge.pos.0, edge.pos.1, edge.pos.2,
                    existing + injected * edge.share
                )
            }
        }

        // V is the line integral over the whole gap: the sum of the edge
        // voltages, not one of them.
        var v = 0.0
        var i = 0.0
        for edge in edges {
            v += engine.getVolt(directionIndex, edge.pos.0, edge.pos.1, edge.pos.2)
            // curlH's +n reference (Ampère's law, matching how curl(H) drives
            // +dE/dt in the update this edge uses) is the current flowing *out*
            // of the port into the rest of the circuit loop, i.e. opposite to
            // the a/b-wave convention's "current into the port from the
            // source". Confirmed empirically too: without this flip, |S11|
            // comes out > 1 everywhere (impossible for this passive one-port) —
            // exactly the mirrored curve 1/S11 produces.
            i += -engine.curlH(direction: directionIndex, pos: edge.pos)
        }
        // Series edges carry one current; averaging the per-edge readings
        // only damps the discretisation noise in it.
        i /= Double(edges.count)

        timeSeconds.append(t)
        voltage.append(v)
        current.append(i)
    }

    public func doPreCurrentUpdates() {}
    public func doPostCurrentUpdates() {}
    public func apply2Current() {}

    public func referenceImpedance(atHertz hertz: Double) -> Double? { impedanceOhm }
}

extension LumpedPortExtension {
    /// Maps a port's two terminals onto the Yee edges between them.
    ///
    /// `GridMesher` pins a fixed line at `bounds.minimum` and `bounds.maximum`
    /// on every axis, so both terminals land exactly on a line and the two
    /// transverse coordinates land exactly on the port's own axis. What it
    /// does *not* do is leave the span between them undivided — `fillInterval`
    /// still fills it to the target cell size. Every edge in that span belongs
    /// to the port.
    ///
    /// Edge `i` along an axis spans `lines[i] ... lines[i + 1]`, so a gap
    /// between line indices `lower` and `upper` owns edges `lower ..< upper`.
    static func gridEdges(
        for port: ResolvedPort,
        unit: LengthUnit,
        lines: GridMesher.Lines
    ) -> [Edge] {
        let directionIndex = axisIndex(port.direction)
        let axisLines = lines.metersLines[directionIndex]
        guard axisLines.count > 1 else { return [] }

        // Transverse axes are degenerate (minimum == maximum), so their
        // "centre" is the port line itself.
        var base = (0, 0, 0)
        for axis in Axis.allCases where axis != port.direction {
            let i = axisIndex(axis)
            let centre = (port.bounds.minimum[axis] + port.bounds.maximum[axis]) / 2
            let index = nearestIndex(lines.metersLines[i], unit.toMeters(centre))
            switch i {
            case 0: base.0 = index
            case 1: base.1 = index
            default: base.2 = index
            }
        }

        let first = nearestIndex(axisLines, unit.toMeters(port.bounds.minimum[port.direction]))
        let last = nearestIndex(axisLines, unit.toMeters(port.bounds.maximum[port.direction]))
        let lower = min(first, last)
        let upper = max(first, last)

        let span: Range<Int>
        if lower < upper {
            span = lower..<upper
        } else {
            // A gap thinner than one cell still has to drive something: fall
            // back to the single edge at the lower terminal. Clamped to the
            // last edge, since edge `i` reads `lines[i + 1]`.
            let start = min(lower, axisLines.count - 2)
            span = start..<(start + 1)
        }

        let lengths = span.map { axisLines[$0 + 1] - axisLines[$0] }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return [] }

        return zip(span, lengths).map { index, length in
            var pos = base
            switch directionIndex {
            case 0: pos.0 = index
            case 1: pos.1 = index
            default: pos.2 = index
            }
            return Edge(pos: pos, share: length / total)
        }
    }
}


// MARK: - 4b. Waveguide port

/// A rectangular waveguide port: a TE_m0 mode imposed over a user-drawn
/// cross-section, and the same mode's amplitude read back for S-parameters.
///
/// Where a lumped port is a two-terminal circuit element, this is a *field*
/// boundary. The user gives a rectangle and a propagation axis; the mode's
/// transverse profile follows from the rectangle's broad dimension:
///
///     E_v(u) = sin(m·π·(u − u₀) / a),  E_u = 0
///
/// with `a` the extent along the broad transverse axis `u`, `v` the other
/// transverse axis, and `m` the mode index (1 = TE₁₀, the fundamental).
///
/// Two consequences of that profile are what make a waveguide port unlike a
/// lumped one, and both are handled here rather than left to the caller:
///
/// - **Cutoff.** The mode only propagates above `f_c = m·c/(2a√(εrµr))`.
///   Below it the fields are evanescent, there is no travelling wave, and a
///   reflection coefficient is meaningless — `referenceImpedance` returns nil
///   there instead of a number the DFT would happily turn into a plot.
/// - **Dispersion.** The wave impedance `η / √(1 − (f_c/f)²)` is a function of
///   frequency, rising without bound toward cutoff. A single reference
///   impedance, the way a lumped port uses 50 Ω, would be wrong everywhere
///   except one frequency.
///
/// The excitation is a *soft* source: it adds the mode's field on the port
/// plane each step rather than enforcing it, so the plane stays transparent to
/// whatever comes back. The cost is that it launches in **both** directions,
/// and that is why the port drives one plane and measures at another.
///
/// Measuring where you inject cannot work. At the source plane the backward
/// wave the source itself launched is present alongside the forward one, and
/// the a/b decomposition has no way to tell it from a genuine reflection — a
/// perfectly matched guide reads as |S11| ≈ 1. So the region's **depth along
/// the propagation axis is the de-embedding distance**: the source sits on the
/// face it launches from, the probe sits on the opposite face, and the
/// source's own backward wave travels away from the probe instead of through
/// it. A deeper region buys more separation; it needs to be at least a few
/// cells, and evanescent junk near a discontinuity dies out over roughly the
/// guide's transverse dimension.
///
/// The port still belongs at the end of a guide with an absorbing boundary
/// behind it, so the backward wave leaves rather than returning later.
///
/// **Accuracy caveat, measured not guessed.** `absorbingBoundary` here is a
/// graded lossy layer tuned for free-space plane waves, and a guided mode is
/// neither: its wave impedance is `Z_TE`, not `η`, and its phase velocity is
/// above c. Terminating a WR-90 guide with it rings down in 2400 steps against
/// 12000 for a shorting wall — so it absorbs, but only about five times better
/// than a short circuit, leaving roughly two thirds of the amplitude coming
/// back per bounce. The standing wave that produces is real, and this port
/// reports it faithfully; what it means is that |S11| from a nominally matched
/// waveguide will read several dB rather than the near-zero a true PML would
/// give. Mode geometry, cutoff and dispersion are unaffected. Fixing it is a
/// boundary-condition job, not a port one.
public final class WaveguidePortExtension: EngineExtension, PortRecorder {
    /// One Yee edge on the port plane, with everything needed to convert
    /// between the solver's edge quantities and physical fields.
    public struct Sample {
        public let pos: (Int, Int, Int)
        /// The mode profile at this edge's transverse coordinate.
        public let weight: Double
        /// Length of the primary (E) edge, metres. `volt / eLength` is E.
        public let eLength: Double
        /// Length of the dual (H) edge, metres. `curr / hLength` is H.
        public let hLength: Double

        public init(pos: (Int, Int, Int), weight: Double, eLength: Double, hLength: Double) {
            self.pos = pos
            self.weight = weight
            self.eLength = eLength
            self.hLength = hLength
        }
    }

    public let priority = 100
    public let extensionName: String

    private let handle: EngineHandle
    /// Axis index the modal E field points along (the transverse axis that is
    /// *not* the broad one).
    private let eIndex: Int
    /// Axis index the modal transverse H field points along.
    private let hIndex: Int
    /// Edges the source drives.
    private let drive: [Sample]
    /// Edges the mode amplitude is read from, one region-depth downstream.
    private let probe: [Sample]
    /// Σ weight² over `probe`, the denominator of the mode-overlap projection.
    private let weightNorm: Double
    private let cutoffHertz: Double
    /// √(µ/ε) of whatever fills the guide — the plane-wave impedance the
    /// modal impedance is derived from.
    private let mediumImpedance: Double
    /// +1 when the port launches along +axis, −1 when reversed. Flips which
    /// direction counts as outgoing.
    private let orientation: Double
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
        eIndex: Int,
        hIndex: Int,
        drive: [Sample],
        probe: [Sample],
        cutoffHertz: Double,
        mediumImpedance: Double,
        isReversed: Bool,
        excitation: Excitation,
        frequency: FrequencyRange,
        isExcited: Bool,
        amplitude: Double,
        dT: @escaping () -> Double
    ) {
        self.extensionName = name
        self.handle = handle
        self.eIndex = eIndex
        self.hIndex = hIndex
        self.drive = drive
        self.probe = probe
        self.weightNorm = probe.reduce(0) { $0 + $1.weight * $1.weight }
        self.cutoffHertz = cutoffHertz
        self.mediumImpedance = mediumImpedance
        self.orientation = isReversed ? -1 : 1
        self.excitation = excitation
        self.frequency = frequency
        self.isExcited = isExcited
        self.amplitude = amplitude
        self.dT = dT
    }

    /// Cutoff of the excited mode, hertz. Surfaced so the runner can warn when
    /// the swept band sits below it.
    public var cutoffFrequencyHertz: Double { cutoffHertz }

    public func doPreVoltageUpdates() {}
    public func doPostVoltageUpdates() {}

    public func apply2Voltages() {
        guard let engine = handle.engine, weightNorm > 0 else { return }
        let t = Double(engine.numTS) * dT()

        if isExcited {
            let waveform = ExcitationWaveformSampler.value(
                excitation: excitation,
                frequency: frequency,
                timeSeconds: t
            )
            let level = amplitude * waveform
            // `volt` is E·dl, so imposing a field of `level · weight` means
            // adding that times the edge length.
            for sample in drive {
                let existing = engine.getVolt(eIndex, sample.pos.0, sample.pos.1, sample.pos.2)
                engine.setVolt(
                    eIndex,
                    sample.pos.0, sample.pos.1, sample.pos.2,
                    existing + level * sample.weight * sample.eLength
                )
            }
        }

        // Project the plane's fields onto the mode: ⟨field, profile⟩ / ⟨profile,
        // profile⟩. Anything on the plane that is not this mode — higher modes,
        // evanescent junk near a discontinuity — is orthogonal to the profile
        // and drops out of the sum, which is the point of doing it this way
        // rather than sampling one cell in the middle.
        var eAmplitude = 0.0
        var hAmplitude = 0.0
        for sample in probe {
            let volt = engine.getVolt(eIndex, sample.pos.0, sample.pos.1, sample.pos.2)
            let curr = engine.getCurr(hIndex, sample.pos.0, sample.pos.1, sample.pos.2)
            eAmplitude += volt / sample.eLength * sample.weight
            hAmplitude += curr / sample.hLength * sample.weight
        }
        eAmplitude /= weightNorm
        hAmplitude /= weightNorm

        timeSeconds.append(t)
        voltage.append(eAmplitude)
        // Same sign convention as the lumped port: positive current flows out
        // of the port into the structure, so a forward-travelling mode gives
        // V/I = +Z. `orientation` carries the reversed case.
        current.append(-hAmplitude * orientation)
    }

    public func doPreCurrentUpdates() {}
    public func doPostCurrentUpdates() {}
    public func apply2Current() {}

    /// TE-mode wave impedance, `η / √(1 − (f_c/f)²)`.
    ///
    /// Nil at or below cutoff: the mode is evanescent there, carries no power,
    /// and its "impedance" is purely imaginary.
    public func referenceImpedance(atHertz hertz: Double) -> Double? {
        guard hertz > cutoffHertz, cutoffHertz.isFinite else { return nil }
        let ratio = cutoffHertz / hertz
        let factor = (1 - ratio * ratio).squareRoot()
        guard factor > 1e-6 else { return nil }
        return mediumImpedance / factor
    }
}


extension WaveguidePortExtension {
    /// Everything needed to instantiate a port from the user's rectangle.
    public struct Plan {
        public let eIndex: Int
        public let hIndex: Int
        /// Edges on the launch face.
        public let drive: [Sample]
        /// Edges on the opposite face, where the mode is measured.
        public let probe: [Sample]
        public let cutoffHertz: Double
        public let mediumImpedance: Double
        /// Extent of the broad transverse dimension, metres — `a` in
        /// `f_c = m·c/(2a)`. Reported so the UI can show it back.
        public let broadWidthMeters: Double
    }

    /// Maps a waveguide port's rectangle onto the Yee grid and works out its
    /// mode.
    ///
    /// The broad transverse axis — the longer of the two — is taken as `u`,
    /// the one the `sin(m·π·u/a)` profile varies along, and the modal E field
    /// then points along the narrow axis `v`. That is the TE_m0 convention:
    /// for WR-90 held the usual way up, `a` is the 22.86 mm wall and E is
    /// vertical across the 10.16 mm one. Choosing it from the geometry rather
    /// than asking means a port drawn either way round still excites the
    /// fundamental rather than something that cannot propagate.
    public static func plan(
        for port: ResolvedPort,
        unit: LengthUnit,
        lines: GridMesher.Lines,
        op: Operator,
        materialProvider: CADMaterialProvider
    ) -> Plan? {
        let dIndex = axisIndex(port.direction)
        let (first, second) = port.direction.perpendicular

        let span = { (axis: Axis) in port.bounds.maximum[axis] - port.bounds.minimum[axis] }
        let (broad, narrow) = span(first) >= span(second) ? (first, second) : (second, first)
        let uIndex = axisIndex(broad), vIndex = axisIndex(narrow)

        let uLines = lines.metersLines[uIndex]
        let vLines = lines.metersLines[vIndex]
        let dLines = lines.metersLines[dIndex]
        guard uLines.count > 1, vLines.count > 1, !dLines.isEmpty else { return nil }

        let uMin = unit.toMeters(port.bounds.minimum[broad])
        let uMax = unit.toMeters(port.bounds.maximum[broad])
        let width = uMax - uMin
        guard width > 0 else { return nil }

        // The source sits on the face the port launches from and the probe on
        // the far one, so a reversed port fires from the opposite side of its
        // own box and measures back across it.
        let launchValue = port.isReversed
            ? unit.toMeters(port.bounds.maximum[port.direction])
            : unit.toMeters(port.bounds.minimum[port.direction])
        let probeValue = port.isReversed
            ? unit.toMeters(port.bounds.minimum[port.direction])
            : unit.toMeters(port.bounds.maximum[port.direction])
        let launchIndex = nearestIndex(dLines, launchValue)
        let probeIndex = nearestIndex(dLines, probeValue)
        guard launchIndex != probeIndex else { return nil }

        let uLower = nearestIndex(uLines, uMin)
        let uUpper = nearestIndex(uLines, uMax)
        let vLower = nearestIndex(vLines, unit.toMeters(port.bounds.minimum[narrow]))
        let vUpper = nearestIndex(vLines, unit.toMeters(port.bounds.maximum[narrow]))
        guard uUpper > uLower, vUpper > vLower else { return nil }

        let mode = max(port.modeIndex, 1)
        var drive: [Sample] = []
        var probe: [Sample] = []
        drive.reserveCapacity((uUpper - uLower + 1) * (vUpper - vLower))
        probe.reserveCapacity(drive.capacity)

        for iu in uLower...uUpper {
            // sin() vanishes at both walls, which is exactly right — the
            // tangential E of a TE mode is zero on a perfect conductor — so
            // those edges contribute nothing rather than being special-cased.
            let weight = sin(Double(mode) * Double.pi * (uLines[iu] - uMin) / width)
            guard abs(weight) > 1e-12 else { continue }

            for iv in vLower..<vUpper {
                func sample(onPlane plane: Int) -> Sample? {
                    var pos = (0, 0, 0)
                    switch dIndex {
                    case 0: pos.0 = plane
                    case 1: pos.1 = plane
                    default: pos.2 = plane
                    }
                    switch uIndex {
                    case 0: pos.0 = iu
                    case 1: pos.1 = iu
                    default: pos.2 = iu
                    }
                    switch vIndex {
                    case 0: pos.0 = iv
                    case 1: pos.1 = iv
                    default: pos.2 = iv
                    }
                    let eLength = op.getEdgeLength(vIndex, pos)
                    let hLength = op.getEdgeLength(uIndex, pos, dualMesh: true)
                    guard eLength > 0, hLength > 0 else { return nil }
                    return Sample(pos: pos, weight: weight, eLength: eLength, hLength: hLength)
                }
                if let s = sample(onPlane: launchIndex) { drive.append(s) }
                if let s = sample(onPlane: probeIndex) { probe.append(s) }
            }
        }
        guard !drive.isEmpty, !probe.isEmpty else { return nil }

        // Whatever fills the guide sets both the cutoff and the impedance, so
        // a dielectric-loaded port is not silently treated as air.
        let centre = port.bounds.center
        let coords = (unit.toMeters(centre.x), unit.toMeters(centre.y), unit.toMeters(centre.z))
        let epsR = max(materialProvider.material(direction: vIndex, coords: coords, matType: 0), 1e-9)
        let muR = max(materialProvider.material(direction: vIndex, coords: coords, matType: 2), 1e-9)

        let lightSpeed = 299_792_458.0 / (epsR * muR).squareRoot()
        let cutoff = Double(mode) * lightSpeed / (2 * width)
        let impedance = 376.730_313_668 * (muR / epsR).squareRoot()

        return Plan(
            eIndex: vIndex,
            hIndex: uIndex,
            drive: drive,
            probe: probe,
            cutoffHertz: cutoff,
            mediumImpedance: impedance,
            broadWidthMeters: width
        )
    }
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
    /// Complex reflection coefficient Γ = b/a at `f`.
    ///
    /// The full complex value, not just its magnitude: phase is what makes a
    /// result usable in an RF tool — de-embedding, cascading and impedance
    /// all need it, and a Touchstone file carrying a fabricated 0° would be
    /// worse than no file at all.
    public static func reflection(
        port: PortRecorder,
        atHertz f: Double
    ) -> (real: Double, imaginary: Double)? {
        // A waveguide below its cutoff has no propagating mode to reflect,
        // so there is no meaningful Γ — better to report nothing than a
        // number computed from an impedance that does not exist.
        guard let z0 = port.referenceImpedance(atHertz: f), z0 > 0, z0.isFinite else { return nil }
        let v = dft(time: port.timeSeconds, values: port.voltage, atHertz: f)
        let i = dft(time: port.timeSeconds, values: port.current, atHertz: f)
        let aRe = (v.real + z0 * i.real) / 2, aIm = (v.imag + z0 * i.imag) / 2
        let bRe = (v.real - z0 * i.real) / 2, bIm = (v.imag - z0 * i.imag) / 2

        let aMagSq = aRe * aRe + aIm * aIm
        guard aMagSq > 0 else { return nil }

        // b/a = b·conj(a) / |a|²
        return (
            real: (bRe * aRe + bIm * aIm) / aMagSq,
            imaginary: (bIm * aRe - bRe * aIm) / aMagSq
        )
    }

    /// |S11| in dB.
    public static func s11(port: PortRecorder, atHertz f: Double) -> Double {
        guard let gamma = reflection(port: port, atHertz: f) else { return .infinity }
        let magnitude = (gamma.real * gamma.real + gamma.imaginary * gamma.imaginary).squareRoot()
        return 20 * log10(magnitude)
    }

    /// Phase of S11 in degrees, the companion to `s11`.
    public static func s11PhaseDegrees(
        port: PortRecorder,
        atHertz f: Double
    ) -> Double? {
        guard let gamma = reflection(port: port, atHertz: f) else { return nil }
        return atan2(gamma.imaginary, gamma.real) * 180 / .pi
    }
}

// MARK: - 6. Orchestrator: CADDocument -> Engine -> results

/// One point of a return-loss sweep.
public struct S11Point: Hashable, Codable, Sendable {
    public let hertz: Double
    public let decibels: Double
    /// Phase of S11 in degrees. Optional because runs recorded before phase
    /// was kept have none, and a Touchstone export must say so rather than
    /// invent it.
    public let phaseDegrees: Double?

    public init(hertz: Double, decibels: Double, phaseDegrees: Double? = nil) {
        self.hertz = hertz
        self.decibels = decibels
        self.phaseDegrees = phaseDegrees
    }
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
        /// The port's rectangle collapsed to nothing on the grid — usually a
        /// zero-width region, or one so thin the mesh gave it no cells.
        case degenerateWaveguidePort(String)
        case waveguidePortBelowCutoff(name: String, cutoffHertz: Double)
        case noConductorNearExcitedPort(String)

        public var errorDescription: String? {
            switch self {
            case .noDomain: return "The computational domain is not defined."
            case .modelHasErrors(let n): return "The model has \(n) error(s) — fix them before running the simulation."
            case .noExcitedLumpedPort:
                return "No excited port; there is nothing to compute a return loss from."
            case .degenerateWaveguidePort(let name):
                return "Waveguide port “\(name)” has no cells. Give its region a real extent on both axes across the propagation direction, and check the mesh is fine enough to put at least one cell inside it."
            case .waveguidePortBelowCutoff(let name, let cutoff):
                return String(
                    format: "Waveguide port “%@” is below cutoff over the whole swept band: its fundamental mode "
                        + "starts at %.4f GHz. Nothing propagates below that — widen the port's broad dimension, "
                        + "or raise the frequency range above the cutoff.",
                    name, cutoff / 1e9
                )
            case .noConductorNearExcitedPort(let name):
                return "Port “\(name)” isn't touching a conductor on either terminal. Its resistor would sit alone in free space, perfectly matched to its own reference impedance — the result would be a flat, meaningless S11 near 0 dB. Assign a conductive material (e.g. PEC) to the body the port should feed, or move the port terminals so they meet it."
            }
        }
    }

    /// How many points to sample across the excited frequency range for the
    /// return-loss sweep. A plain (non-FFT) DFT is used, so this is O(N) DFTs
    /// over the recorded time series — fine for a few hundred points.
    public var spectrumPointCount = 121

    /// How a run finished.
    public enum CompletionReason: Equatable, Sendable {
        /// Converged: residual energy fell to the requested decay.
        case energyDecay(decibels: Double, atStep: Int)
        /// Ran out of timesteps first. openEMS warns in this case and so do
        /// we: the time series was truncated while the structure was still
        /// ringing, so the DFT behind S11 sees a cut-off signal and the
        /// spectrum carries leakage — ripple, smeared resonances, unreliable
        /// low-frequency content.
        case stepCapReached(decibels: Double?)
        case stoppedByUser

        public var didConverge: Bool {
            if case .energyDecay = self { return true }
            return false
        }

        public var summary: String {
            switch self {
            case .energyDecay(let decibels, let atStep):
                return String(format: "Converged at %.1f dB after %d steps.", decibels, atStep)
            case .stepCapReached(let decibels):
                guard let decibels else {
                    return "Hit the step cap. No decay criterion applied — the excitation never stops driving."
                }
                return String(
                    format: "Hit the step cap at %.1f dB, short of the decay target. "
                        + "The fields were still ringing, so the spectrum is truncated: expect ripple "
                        + "and unreliable low-frequency content. Raise Max time steps, or loosen Energy decay.",
                    decibels
                )
            case .stoppedByUser:
                return "Stopped."
            }
        }
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var progress: Double = 0
    /// Residual field energy relative to the peak, in dB — the same figure
    /// openEMS prints each status line. `nil` before the first check, or for
    /// a source that never stops driving.
    @Published public private(set) var energyDecayDb: Double?
    /// Why the last run ended. The distinction matters: only `.energyDecay`
    /// means the fields actually rang down, which is the precondition the
    /// S-parameter DFT assumes.
    @Published public private(set) var completionReason: CompletionReason?
    @Published public private(set) var s11DbAtCenter: Double?
    @Published public private(set) var s11Spectrum: [S11Point] = []
    /// One pattern per recorded far-field frequency. Empty unless the run had
    /// far-field recording switched on.
    @Published public private(set) var farFieldPatterns: [FarFieldPattern] = []
    /// Set when far-field recording was asked for but could not be set up, so
    /// the absence of a pattern is explained rather than just observed.
    @Published public private(set) var farFieldWarning: String?
    /// Things the mesher or the material setup could not honour — a rotated
    /// zero-thickness sheet, one smaller than a cell. Published because these
    /// mean a body is silently absent from the physics, which is exactly the
    /// class of problem a user cannot see in the viewport.
    @Published public private(set) var solverWarnings: [String] = []
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
    private var ports: [PortRecorder] = []
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
            spectrum.append(
                S11Point(
                    hertz: f,
                    decibels: PortSpectrum.s11(port: excited, atHertz: f),
                    phaseDegrees: PortSpectrum.s11PhaseDegrees(port: excited, atHertz: f)
                )
            )
        }
        s11Spectrum = spectrum
        s11DbAtCenter = PortSpectrum.s11(port: excited, atHertz: (clampedMin + clampedMax) / 2)
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
        guard resolved.simulation.ports.contains(where: \.isExcited) else {
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

        // Infinitely thin conductors are a boundary condition, not a material.
        var sheetWarnings: [String] = []
        defer { self.solverWarnings = sheetWarnings }
        op.forcedPECEdges = ZeroThicknessConductors.edges(
            bodies: resolved.bodies,
            materials: document.state.materials,
            unit: unit,
            lines: lines,
            maximumHertz: setup.frequency.maximumHertz,
            warnings: &sheetWarnings
        )

        let handle = EngineHandle()
        var portExtensions: [PortRecorder] = []
        var factories: [() -> EngineExtension] = []

        for port in resolved.simulation.ports where port.kind == .lumped {
            let directionIndex = axisIndex(port.direction)

            // Every Yee edge between the two terminals, not just the first:
            // the mesher subdivides the gap whenever it is wider than about
            // a cell and a half.
            let edges = LumpedPortExtension.gridEdges(for: port, unit: unit, lines: lines)
            guard !edges.isEmpty else { continue }

            // Stamp the port's reference impedance across those edges so it
            // is a real R-loaded gap, not just a lossless soft source. They
            // are in series, so each takes the share of R that matches its
            // share of the gap length and the chain adds back up to the
            // reference impedance however the mesher divided the gap.
            for edge in edges {
                op.addLumpedResistor(
                    direction: directionIndex,
                    pos: edge.pos,
                    ohms: port.impedanceOhm * edge.share
                )
            }

            let ext = LumpedPortExtension(
                name: "Port_\(port.name)",
                handle: handle,
                directionIndex: directionIndex,
                edges: edges,
                impedanceOhm: port.impedanceOhm,
                excitation: setup.excitation,
                frequency: setup.frequency,
                isExcited: port.isExcited,
                amplitude: port.amplitude,
                dT: { [weak op] in op?.dT ?? 0 }
            )
            portExtensions.append(ext)
            factories.append { ext }
        }

        for port in resolved.simulation.ports where port.kind == .waveguide {
            guard let plan = WaveguidePortExtension.plan(
                for: port,
                unit: unit,
                lines: lines,
                op: op,
                materialProvider: materialProvider
            ) else {
                throw RunnerError.degenerateWaveguidePort(port.name)
            }

            // A band entirely below cutoff produces no propagating mode at
            // all: the run would be minutes of evanescent decay and an empty
            // spectrum. Say so now, with the number the user needs.
            if setup.frequency.maximumHertz <= plan.cutoffHertz {
                throw RunnerError.waveguidePortBelowCutoff(
                    name: port.name,
                    cutoffHertz: plan.cutoffHertz
                )
            }

            let ext = WaveguidePortExtension(
                name: "Port_\(port.name)",
                handle: handle,
                eIndex: plan.eIndex,
                hIndex: plan.hIndex,
                drive: plan.drive,
                probe: plan.probe,
                cutoffHertz: plan.cutoffHertz,
                mediumImpedance: plan.mediumImpedance,
                isReversed: port.isReversed,
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
        self.energyDecayDb = nil
        self.completionReason = nil

        let maxSteps = UInt(setup.solver.maximumTimeSteps)
        // Also the energy-check interval, which is what sets how far past the
        // threshold a run can overshoot before it notices. `calcEnergy` costs
        // roughly a third of a timestep, so checking every 100 is about 0.3%
        // overhead — cheap enough that granularity is worth more than the
        // saving. At 500 a fast-decaying model would blow through 20 dB
        // between two consecutive checks.
        let chunk: UInt = 100

        let frequency = setup.frequency
        // The end criterion. Negative dB, e.g. -40 means "stop once residual
        // energy is 1e-4 of its peak". A source that never stops driving has
        // no decay to wait for, so the criterion is disabled and the run falls
        // back on the step cap.
        let decayTargetDb = setup.solver.energyDecayDecibels
        let excitationSeconds = ExcitationWaveformSampler.excitationDurationSeconds(
            excitation: setup.excitation,
            frequency: frequency
        )
        let dT = op.dT
        let excitationSteps: UInt? = excitationSeconds.flatMap { seconds -> UInt? in
            guard dT > 0 else { return nil }
            return UInt((seconds / dT).rounded(.up))
        }
        let usesDecayCriterion = decayTargetDb < 0 && excitationSteps != nil
        let excitedPort = resolved.simulation.ports.first(where: \.isExcited)!
        let excitedPortName = excitedPort.name
        let impedanceOhm = excitedPort.impedanceOhm
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
            var peakEnergy = 0.0
            var latestDecayDb: Double?
            var convergedAtStep: UInt?
            var reportedProgress = 0.0

            while done < maxSteps {
                if Task.isCancelled { stopped = true; break }
                let step = min(chunk, maxSteps - done)
                engine.iterateTS(step)
                done += step

                var decayFraction = 0.0
                if usesDecayCriterion {
                    let energy = engine.calcEnergy()
                    peakEnergy = Swift.max(peakEnergy, energy)
                    if peakEnergy > 0, energy > 0 {
                        // Energy is power-like, so 10·log10 — the same
                        // convention openEMS prints and the same one the
                        // Energy decay setting is written in.
                        let db = 10 * log10(energy / peakEnergy)
                        latestDecayDb = db
                        decayFraction = Swift.min(Swift.max(db / decayTargetDb, 0), 1)

                        // Never before the source has finished driving: the
                        // domain starts empty, and a decay test taken then
                        // would end the run at step one.
                        if let excitationSteps, done >= excitationSteps, db <= decayTargetDb {
                            convergedAtStep = done
                            break
                        }
                    }
                }

                // Whichever criterion is nearer to ending the run is the
                // honest measure of progress, and it never goes backwards —
                // residual energy is noisy, and a bar that retreats reads as
                // a fault.
                let fraction = Swift.max(Double(done) / Double(maxSteps), decayFraction)
                reportedProgress = Swift.max(reportedProgress, fraction)
                let shown = reportedProgress
                let shownDb = latestDecayDb
                await MainActor.run { [weak self] in
                    self?.progress = shown
                    self?.energyDecayDb = shownDb
                }
            }

            let didStop = stopped
            let reason: CompletionReason
            if stopped {
                reason = .stoppedByUser
            } else if let convergedAtStep, let db = latestDecayDb {
                reason = .energyDecay(decibels: db, atStep: Int(convergedAtStep))
            } else {
                reason = .stepCapReached(decibels: usesDecayCriterion ? latestDecayDb : nil)
            }
            let finalDecayDb = latestDecayDb
            await MainActor.run { [weak self] in
                self?.completionReason = reason
                self?.energyDecayDb = finalDecayDb
            }
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
            let centerDb = PortSpectrum.s11(port: excited, atHertz: frequency.centerHertz)
            var spectrumBuilder: [S11Point] = []
            spectrumBuilder.reserveCapacity(spectrumPointCount)
            let count = max(spectrumPointCount, 2)
            for i in 0..<count {
                let f = frequency.minimumHertz
                    + (frequency.maximumHertz - frequency.minimumHertz) * Double(i) / Double(count - 1)
                let db = PortSpectrum.s11(port: excited, atHertz: f)
                let phase = PortSpectrum.s11PhaseDegrees(port: excited, atHertz: f)
                spectrumBuilder.append(S11Point(hertz: f, decibels: db, phaseDegrees: phase))
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
        port: PortRecorder?,
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

                let s11Db = PortSpectrum.s11(port: port, atHertz: frequency)
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

    /// Which of the faces `[xMin, xMax, yMin, yMax, zMin, zMax]` end on an
    /// electric wall and which on a magnetic one.
    ///
    /// Every face that is not a magnetic wall is terminated by a perfect
    /// electric conductor on its outermost grid line. For an electric wall
    /// that is all there is. An absorbing face is the graded loss layer set up
    /// before `calcECOperator()`, backed by that wall the way openEMS backs its
    /// PML. A periodic face has no implementation and falls back to it, which
    /// the resolver warns about.
    ///
    /// No face is left to the engine's bare edges: those are not an open
    /// boundary but a PEC on the lower faces and a PMC half a cell beyond the
    /// upper ones, which is how "periodic" and the far side of every absorber
    /// used to end.
    nonisolated static func wallFaces(_ boundaries: BoundarySettings) -> (electric: [Bool], magnetic: [Bool]) {
        let faces: [BoundaryCondition] = [
            boundaries.xMin, boundaries.xMax,
            boundaries.yMin, boundaries.yMax,
            boundaries.zMin, boundaries.zMax
        ]
        let magnetic = faces.map { $0 == .magnetic }
        return (electric: magnetic.map { !$0 }, magnetic: magnetic)
    }

    /// Applies `wallFaces` to the operator, after `calcECOperator()` and
    /// before the engine is built.
    private func applyHardWallBoundaries(op: Operator, boundaries: BoundarySettings) {
        let walls = Self.wallFaces(boundaries)
        op.applyElectricBC(walls.electric)
        op.applyMagneticBC(walls.magnetic)
    }

    private func makeAbsorbingBoundary(boundaries: BoundarySettings, lines: [[Double]]) -> AbsorbingBoundarySettings? {
        let faces: [BoundaryCondition] = [
            boundaries.xMin, boundaries.xMax,
            boundaries.yMin, boundaries.yMax,
            boundaries.zMin, boundaries.zMax
        ]
        let absorbingFaces = faces.map { $0 == .pml }
        guard absorbingFaces.contains(true), boundaries.pmlCellCount > 0 else { return nil }

        // Gedney's estimate for a graded absorber's peak conductivity,
        // σ ≈ (m+1) / (150π·Δ), evaluated **at each boundary** — Δ is the cell
        // size in that layer, not somewhere else in the model.
        //
        // This used to use the smallest cell anywhere in the domain, called
        // conservative on the grounds that over-absorbing beats
        // under-absorbing. It is not conservative, it is backwards: the
        // optimum is optimal precisely because it balances absorption inside
        // the layer against reflection off the layer's *front face*, and too
        // much conductivity turns the absorber into a mirror. A board meshed
        // at 0.4 mm through its substrate but 3.5 mm out in the padding got a
        // σ roughly nine times too high on every face.
        let order = 3.0
        let cells = max(boundaries.pmlCellCount, 1)

        var sigmaMax = [Double](repeating: 0, count: 6)
        for dim in 0..<3 {
            let axis = lines[dim]
            guard axis.count > 1 else { continue }
            let usable = min(cells, axis.count - 1)

            // Mean cell size across the layer on each side.
            let lowSpan = axis[usable] - axis[0]
            let highSpan = axis[axis.count - 1] - axis[axis.count - 1 - usable]
            for (face, span) in [(2 * dim, lowSpan), (2 * dim + 1, highSpan)] {
                let mean = span / Double(usable)
                sigmaMax[face] = mean > 0 ? (order + 1) / (150 * .pi * mean) : 0
            }
        }

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
        //
        // The terminal itself is sampled first, and it is the case that
        // matters most: a zero-thickness sheet has no volume for a stepped
        // sample to land in, so a probe feeding a patch — terminal sitting
        // exactly on the PEC surface, the most correct way to draw it — read
        // as unconnected however far the step went. Sheets are a documented,
        // supported construct here (`ShapeContainment` keeps them a surface
        // precisely so `snapToBodyEdges` can put a grid line on them), so a
        // port landing on one is a connection, not an error.
        func touchesConductor(at terminalMeters: Vec3) -> Bool {
            if isConductive(terminalMeters) { return true }
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

}

// MARK: - Grid index helpers

/// Shared by the runner and by `LumpedPortExtension.gridEdges`, which has to
/// resolve the same coordinates onto the same lines.
func axisIndex(_ axis: Axis) -> Int {
    switch axis {
    case .x: return 0
    case .y: return 1
    case .z: return 2
    }
}

func nearestIndex(_ lines: [Double], _ value: Double) -> Int {
    guard !lines.isEmpty else { return 0 }
    var bestIndex = 0
    var bestDistance = Double.greatestFiniteMagnitude
    for (index, line) in lines.enumerated() {
        let d = abs(line - value)
        if d < bestDistance { bestDistance = d; bestIndex = index }
    }
    return bestIndex
}