//
//  FDTDSolver.swift
//  Port of openEMS (Thorsten Liebig, GPLv3) Engine + Operator core.
//
//  Original: engine.h/.cpp, operator.h/.cpp  (openEMS project)
//  License note: openEMS is GPLv3. This derivative Swift port must be
//  distributed under GPLv3 (or a compatible license) as well.
//
//  Architecture:
//   - FDTDArray      : flat storage replacement for ArrayLib::ArrayNIJK
//   - EngineExtension: protocol replacement for Engine_Extension
//   - Engine         : the actual leap-frog Yee solver (self-contained)
//   - MaterialProvider: protocol you implement against your existing CAD/CSX
//                       infrastructure (fills the role of ContinuousStructure /
//                       CSPropMaterial / CSPrimBox lookups in the original code)
//   - Operator       : grid, EC/VV/VI/II/IV coefficients, timestep, boundaries
//
//  FDTD_FLOAT -> Double here for accuracy during development; switch to
//  Float if you need the memory/throughput profile of the original.
//

import Foundation

public typealias FDTDFloat = Double

// MARK: - Basic constants (tools/constants.h)

public struct FDTDConstants {
    public static let EPS0 = 8.8541878176e-12   // vacuum permittivity [F/m]
    public static let MUE0 = 4.0 * Double.pi * 1e-7 // vacuum permeability [H/m]
    public static let C0   = 299792458.0        // speed of light [m/s]
}

// MARK: - FDTDArray  (replacement for ArrayLib::ArrayNIJK)

/// A dense 4D array: component n in {0,1,2} (x/y/z-directed edge/face quantity)
/// times a structured (x,y,z) grid of size numLines[0..2].
///
/// Storage layout: `idx = ((x*ny + y)*nz + z)*3 + n` — **component-interleaved**,
/// i.e. a cell's x/y/z components sit adjacent in memory, unlike openEMS's
/// original layout (`((n*nx + x)*ny + y)*nz + z`) which keeps each component
/// in its own plane, `nx*ny*nz` elements apart. The update kernels read all
/// three components of a cell back-to-back (`for n in 0..<3`), so this puts
/// them on one cache line instead of three. Measured gain is real but small
/// (~4% either threaded or not): the kernels are dominated by the curl's
/// y/z-strided *neighbour* reads, not the three-component read. z remains the
/// fastest-varying spatial index either way, keeping those neighbours
/// contiguous.
public final class FDTDArray {
    public let name: String
    public let numLines: (Int, Int, Int)
    /// Raw storage, not `[FDTDFloat]`: a Swift `Array`'s subscript performs a
    /// copy-on-write uniqueness check on every access — cheap single-
    /// threaded, but under concurrent access from multiple cores (as
    /// `Engine`'s chunked parallel update loops do) those checks all hit the
    /// same buffer's reference count and cause exactly the kind of
    /// cross-core cache-line contention that erases any benefit from
    /// splitting the work — confirmed by benchmark: with `[FDTDFloat]`
    /// storage, "parallel" was consistently *slower* than sequential even on
    /// a 512k-cell grid. A bare pointer has no such bookkeeping.
    private let buffer: UnsafeMutablePointer<FDTDFloat>
    private let count: Int

    public init(name: String, numLines: (Int, Int, Int)) {
        self.name = name
        self.numLines = numLines
        self.count = 3 * numLines.0 * numLines.1 * numLines.2
        self.buffer = .allocate(capacity: count)
        self.buffer.initialize(repeating: 0, count: count)
    }

    deinit {
        buffer.deinitialize(count: count)
        buffer.deallocate()
    }

    @inline(__always)
    private func index(_ n: Int, _ x: Int, _ y: Int, _ z: Int) -> Int {
        ((x * numLines.1 + y) * numLines.2 + z) * 3 + n
    }

    @inline(__always)
    public func get(_ n: Int, _ x: Int, _ y: Int, _ z: Int) -> FDTDFloat {
        buffer[index(n, x, y, z)]
    }

    @inline(__always)
    public func set(_ n: Int, _ x: Int, _ y: Int, _ z: Int, _ value: FDTDFloat) {
        buffer[index(n, x, y, z)] = value
    }

    @inline(__always)
    public func get(_ n: Int, _ pos: (Int, Int, Int)) -> FDTDFloat {
        get(n, pos.0, pos.1, pos.2)
    }

    @inline(__always)
    public func set(_ n: Int, _ pos: (Int, Int, Int), _ value: FDTDFloat) {
        set(n, pos.0, pos.1, pos.2, value)
    }

    public func fill(_ value: FDTDFloat) {
        for i in 0..<count { buffer[i] = value }
    }
}

// MARK: - Engine_Extension replacement

/// Protocol mirror of Engine_Extension. Extensions (PML, lumped elements,
/// excitation, conducting sheet, ...) hook into the leap-frog loop at these
/// six points, exactly like in openEMS.
public protocol EngineExtension: AnyObject {
    var priority: Int { get }
    var extensionName: String { get }

    func doPreVoltageUpdates()
    func doPostVoltageUpdates()
    func apply2Voltages()

    func doPreCurrentUpdates()
    func doPostCurrentUpdates()
    func apply2Current()
}

// MARK: - Engine  (port of engine.h / engine.cpp)

/// The core FDTD (Yee-grid) leap-frog engine.
/// Uses Operator-provided coefficient fields VV, VI, II, IV to update the
/// electric ("volt") and magnetic ("curr") degrees of freedom.
public final class Engine {

    public enum EngineType { case basic, sse, unknown }

    public private(set) var type: EngineType = .basic
    public private(set) var numTS: UInt = 0

    public let op: Operator
    public let numLines: (Int, Int, Int)

    public private(set) var volt: FDTDArray
    public private(set) var curr: FDTDArray

    private var extensions: [EngineExtension] = []

    /// The sign tangential H takes when imaged below index 0, one per axis.
    ///
    /// No H is stored below the first line, so the curl on a lower face uses
    /// the image of the H just inside. Tangential H is even across an
    /// electric wall (+1) and odd across a magnetic one (−1). Taken from
    /// `Operator.magneticWalls` when the engine starts.
    private var lowerImageSigns: (Double, Double, Double) = (1, 1, 1)

    /// Axes whose upper face is a magnetic wall. After every current update
    /// the H just outside those faces is overwritten with the image of the H
    /// just inside, which puts the wall exactly on the last grid line.
    private var magneticUpperAxes: [Int] = []

    // MARK: Construction

    /// Mirrors Engine::New(op)
    public static func make(op: Operator) -> Engine {
        let e = Engine(op: op)
        e.initEngine()
        return e
    }

    public init(op: Operator) {
        self.op = op
        self.numLines = op.numLines
        self.volt = FDTDArray(name: "volt", numLines: op.numLines)
        self.curr = FDTDArray(name: "curr", numLines: op.numLines)
        configureWalls()
    }

    public func initEngine() {
        numTS = 0
        volt = FDTDArray(name: "volt", numLines: numLines)
        curr = FDTDArray(name: "curr", numLines: numLines)
        configureWalls()
        initExtensions()
        sortExtensionsByPriority()
    }

    private func configureWalls() {
        let walls = op.magneticWalls
        guard walls.count == 6 else { return }
        func sign(_ axis: Int) -> Double { walls[2 * axis] ? -1 : 1 }
        lowerImageSigns = (sign(0), sign(1), sign(2))
        magneticUpperAxes = (0..<3).filter { walls[2 * $0 + 1] }
    }

    public func reset() {
        volt = FDTDArray(name: "volt", numLines: numLines)
        curr = FDTDArray(name: "curr", numLines: numLines)
        extensions.removeAll()
    }

    private func initExtensions() {
        // Wire up any extensions registered on the Operator, same as
        // Engine::InitExtensions() consulting Operator_Extension::CreateEngineExtention()
        extensions = op.makeEngineExtensions()
    }

    private func sortExtensionsByPriority() {
        extensions.sort { $0.priority > $1.priority }
    }

    // MARK: Field access (Get/SetVolt / Get/SetCurr)

    @inline(__always)
    public func getVolt(_ n: Int, _ x: Int, _ y: Int, _ z: Int) -> FDTDFloat { volt.get(n, x, y, z) }
    @inline(__always)
    public func setVolt(_ n: Int, _ x: Int, _ y: Int, _ z: Int, _ value: FDTDFloat) { volt.set(n, x, y, z, value) }
    @inline(__always)
    public func getCurr(_ n: Int, _ x: Int, _ y: Int, _ z: Int) -> FDTDFloat { curr.get(n, x, y, z) }
    @inline(__always)
    public func setCurr(_ n: Int, _ x: Int, _ y: Int, _ z: Int, _ value: FDTDFloat) { curr.set(n, x, y, z, value) }

    // MARK: Extension hook dispatch (Engine::DoPre/PostXUpdates, Apply2X)

    private func doPreVoltageUpdates() {
        // reverse order: highest priority gets access to voltages LAST
        for ext in extensions.reversed() { ext.doPreVoltageUpdates() }
    }
    private func doPostVoltageUpdates() {
        for ext in extensions { ext.doPostVoltageUpdates() }
    }
    private func apply2Voltages() {
        for ext in extensions { ext.apply2Voltages() }
    }
    private func doPreCurrentUpdates() {
        for ext in extensions.reversed() { ext.doPreCurrentUpdates() }
    }
    private func doPostCurrentUpdates() {
        for ext in extensions { ext.doPostCurrentUpdates() }
    }
    private func apply2Current() {
        for ext in extensions { ext.apply2Current() }
    }

    // MARK: Core Yee update kernels
    //
    // NOTE on fidelity: the source text for engine.cpp lost all '<','>','&'
    // characters in transit, so the exact boundary-shift formula could not be
    // recovered verbatim. What follows is the standard explicit leap-frog
    // Yee-grid update (curl-H drives E, curl-E drives H) using the same
    // "shift" idea openEMS uses to avoid negative/out-of-range indices at
    // domain boundaries (mathematically: zero curl contribution across the
    // domain edge, which is what a zero-length ghost step gives you).
    // If you have access to an unmangled engine.cpp, diff this against it.

    /// The discrete curl(H) circulating around the Yee edge `(direction,
    /// pos)` — i.e. the total conduction+displacement current threading the
    /// dual face at that edge (Ampère's law), exactly the quantity that
    /// drives the E-field update there. This is also the physically correct
    /// "branch current" for a lumped element sitting on that edge: **not**
    /// `getCurr(direction, pos)`, which is the H-field component pointing
    /// *along* the edge's own direction — on an axis of symmetry (e.g. the
    /// centerline of a dipole) that component is identically zero by
    /// symmetry, even though real current is flowing.
    ///
    /// On a lower face there is no H below index 0, so the missing value is
    /// the image of the one just inside. Across an electric wall it is equal,
    /// the two terms cancel, and tangential E on the face never moves. Across
    /// a magnetic wall it is opposite, which leaves that field free.
    public func curlH(direction n: Int, pos: (Int, Int, Int)) -> Double {
        let nP  = (n + 1) % 3
        let nPP = (n + 2) % 3

        let backP = componentIndex(pos, nP) > 0
            ? curr.get(nPP, shifted(pos, dim: nP, by: -1))
            : lowerImageSign(nP) * curr.get(nPP, pos)
        let backPP = componentIndex(pos, nPP) > 0
            ? curr.get(nP, shifted(pos, dim: nPP, by: -1))
            : lowerImageSign(nPP) * curr.get(nP, pos)

        return curr.get(nPP, pos) - backP
             - curr.get(nP,  pos) + backPP
    }

    @inline(__always) private func lowerImageSign(_ axis: Int) -> Double {
        axis == 0 ? lowerImageSigns.0 : (axis == 1 ? lowerImageSigns.1 : lowerImageSigns.2)
    }

    /// Below this many cells in the range being updated, fall back to the
    /// plain sequential loop. Above it, split into core-sized chunks so
    /// dispatch cost stays O(cores), not O(numX).
    ///
    /// Set from measurement, and deliberately low. Two earlier values were
    /// wrong in opposite directions: parallelising unconditionally (one
    /// `concurrentPerform` iteration *per X-plane*) made a ~16k-cell run
    /// 3.7x **slower**, because it re-dispatched across every core twice per
    /// timestep for planes with only microseconds of work each.
    /// Over-correcting to 400k cells then disabled parallelism for every
    /// realistic antenna model — a 2.4 GHz dipole meshes to roughly 2k–30k
    /// cells, so nothing ever crossed the threshold and runs stayed
    /// stubbornly single-core.
    ///
    /// With core-sized chunking plus raw `FDTDArray` storage, the measured
    /// speedup on a 16-thread machine is positive across the whole practical
    /// range — 2.0x at 768 cells, 5.1x at 16k, 6.8x at 512k — so the only
    /// grids worth excluding are degenerate ones whose whole run finishes
    /// instantly anyway.
    ///
    /// `var`, not `let`, so tests can force the sequential path for a
    /// controlled before/after comparison.
    static var parallelWorkThreshold = 1_000

    /// Port of Engine::UpdateVoltages(startX, numX)
    /// Advances the electric field ("volt", E on Yee edges) using curl(H).
    ///
    /// Parallelized across X-plane chunks: this only ever *writes* `volt`
    /// within its own chunk's planes, and only *reads* `curr`, which no code
    /// mutates during this phase (it was last written in the previous
    /// timestep's updateCurrents and won't be touched again until the next
    /// one) — so concurrent chunks never race, even though a curl at plane
    /// `x` may read `curr` from a neighboring plane `x-1` in another chunk.
    public func updateVoltages(startX: Int, numX: Int) {
        guard numX > 0 else { return }
        let (_, ny, nz) = numLines
        guard numX * ny * nz >= Self.parallelWorkThreshold else {
            for i in 0..<numX { updateVoltagesPlane(startX + i) }
            return
        }
        let chunkCount = Swift.min(numX, Swift.max(1, ProcessInfo.processInfo.activeProcessorCount))
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            let (lo, hi) = Self.chunkRange(chunk, of: chunkCount, over: numX)
            for i in lo..<hi { self.updateVoltagesPlane(startX + i) }
        }
    }

    /// Splits `[0, total)` into `count` near-equal, contiguous chunks —
    /// chunk `index`'s half-open range.
    private static func chunkRange(_ index: Int, of count: Int, over total: Int) -> (Int, Int) {
        let base = total / count
        let remainder = total % count
        let lo = index * base + Swift.min(index, remainder)
        let hi = lo + base + (index < remainder ? 1 : 0)
        return (lo, hi)
    }

    private func updateVoltagesPlane(_ x: Int) {
        let (_, ny, nz) = numLines
        var pos = (x: x, y: 0, z: 0)
        for y in 0..<ny {
            pos.y = y
            for z in 0..<nz {
                pos.z = z
                for n in 0..<3 {
                    let curl = curlH(direction: n, pos: pos)

                    let vv = op.getVV(n, pos.x, pos.y, pos.z)
                    let vi = op.getVI(n, pos.x, pos.y, pos.z)

                    let newV = vv * volt.get(n, pos) + vi * curl
                    volt.set(n, pos, newV)
                }
            }
        }
    }

    /// Port of Engine::UpdateCurrents(startX, numX)
    /// Advances the magnetic field ("curr", H on Yee faces) using curl(E).
    ///
    /// Parallelized the same way as `updateVoltages`, with the roles of
    /// `volt`/`curr` swapped: only writes `curr` at its own plane, only
    /// reads `volt`, which nothing mutates during this phase.
    public func updateCurrents(startX: Int, numX: Int) {
        guard numX > 0 else { return }
        let (_, ny, nz) = numLines
        guard numX * ny * nz >= Self.parallelWorkThreshold else {
            for i in 0..<numX { updateCurrentsPlane(startX + i) }
            return
        }
        let chunkCount = Swift.min(numX, Swift.max(1, ProcessInfo.processInfo.activeProcessorCount))
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            let (lo, hi) = Self.chunkRange(chunk, of: chunkCount, over: numX)
            for i in lo..<hi { self.updateCurrentsPlane(startX + i) }
        }
    }

    private func updateCurrentsPlane(_ x: Int) {
        let (_, ny, nz) = numLines
        var pos = (x: x, y: 0, z: 0)
        for y in 0..<ny {
            pos.y = y
            for z in 0..<nz {
                pos.z = z
                for n in 0..<3 {
                    let nP  = (n + 1) % 3
                    let nPP = (n + 2) % 3

                    let shiftP:  Int = componentIndex(pos, nP)  < numLines(nP)  - 1 ? 1 : 0
                    let shiftPP: Int = componentIndex(pos, nPP) < numLines(nPP) - 1 ? 1 : 0

                    let posP  = shifted(pos, dim: nP,  by: shiftP)
                    let posPP = shifted(pos, dim: nPP, by: shiftPP)

                    let curl = volt.get(nP,  posPP) - volt.get(nP,  pos)
                             - volt.get(nPP, posP)  + volt.get(nPP, pos)

                    let ii = op.getII(n, pos.x, pos.y, pos.z)
                    let iv = op.getIV(n, pos.x, pos.y, pos.z)

                    let newI = ii * curr.get(n, pos) + iv * curl
                    curr.set(n, pos, newI)
                }
            }
        }
    }

    // small helpers for tuple-position component access
    @inline(__always) private func componentIndex(_ p: (x: Int, y: Int, z: Int), _ dim: Int) -> Int {
        dim == 0 ? p.x : (dim == 1 ? p.y : p.z)
    }
    @inline(__always) private func numLines(_ dim: Int) -> Int {
        dim == 0 ? numLines.0 : (dim == 1 ? numLines.1 : numLines.2)
    }
    @inline(__always) private func shifted(_ p: (x: Int, y: Int, z: Int), dim: Int, by delta: Int) -> (Int, Int, Int) {
        var x = p.x, y = p.y, z = p.z
        switch dim {
        case 0: x += delta
        case 1: y += delta
        default: z += delta
        }
        return (x, y, z)
    }

    // MARK: Top-level iteration (Engine::IterateTS)

    /// Advance the simulation by `iterTS` timesteps. Returns false on failure
    /// (mirrors the bool return of the original, reserved for future error
    /// signalling from extensions).
    @discardableResult
    public func iterateTS(_ iterTS: UInt) -> Bool {
        for _ in 0..<iterTS {
            doPreVoltageUpdates()
            updateVoltages(startX: 0, numX: numLines.0)
            doPostVoltageUpdates()
            apply2Voltages()

            doPreCurrentUpdates()
            updateCurrents(startX: 0, numX: numLines.0)
            if !magneticUpperAxes.isEmpty { imageCurrentsAcrossUpperMagneticWalls() }
            doPostCurrentUpdates()
            apply2Current()

            numTS += 1
        }
        return true
    }

    /// Rewrites the tangential H half a cell beyond each upper magnetic wall
    /// as the negative of the H half a cell inside it.
    ///
    /// That is the image a perfect magnetic conductor on the last grid line
    /// implies, and it is what the next voltage update reads for the
    /// tangential E lying on the wall. Left alone, the outside H is never
    /// driven and stays zero — also a magnetic wall, but half a cell beyond
    /// the domain rather than on its edge.
    private func imageCurrentsAcrossUpperMagneticWalls() {
        for axis in magneticUpperAxes {
            let last = numLines(axis) - 1
            guard last > 0 else { continue }
            let first = (axis + 1) % 3, second = (axis + 2) % 3
            for a in 0..<numLines(first) {
                for b in 0..<numLines(second) {
                    let outside = setting(setting(setting((0, 0, 0), axis, last), first, a), second, b)
                    let inside = setting(outside, axis, last - 1)
                    curr.set(first, outside, -curr.get(first, inside))
                    curr.set(second, outside, -curr.get(second, inside))
                }
            }
        }
    }

    @inline(__always) private func setting(_ p: (Int, Int, Int), _ dim: Int, _ value: Int) -> (Int, Int, Int) {
        switch dim {
        case 0: return (value, p.1, p.2)
        case 1: return (p.0, value, p.2)
        default: return (p.0, p.1, value)
        }
    }

    /// Total field energy left in the domain, as an unnormalised proxy.
    ///
    /// Port of openEMS's `CalcFastEnergy`. The sum is
    /// `Σ volt² + Σ curr²` over every edge and every direction — *not* the
    /// physical `½∫(ε|E|² + µ|H|²)dV`, because the per-edge C and L that
    /// would weight it are scratch buffers `calcECOperator()` releases once
    /// the update coefficients exist.
    ///
    /// That is fine for what this is used for, and only for that: the end
    /// criterion compares energy against the **peak of this same quantity**,
    /// so any weighting that does not change over the run cancels in the
    /// ratio. It is a decay monitor, not a measurement — do not report it as
    /// joules, and do not compare it between two different meshes.
    public func calcEnergy() -> Double {
        var total = 0.0
        for n in 0..<3 {
            for x in 0..<numLines.0 {
                for y in 0..<numLines.1 {
                    for z in 0..<numLines.2 {
                        let v = volt.get(n, x, y, z)
                        let i = curr.get(n, x, y, z)
                        total += v * v + i * i
                    }
                }
            }
        }
        return total
    }

    public func nextInterval(currSpeed: Float) {
        // hook for adaptive/streaming visualisation, no-op by default
        _ = currSpeed
    }
}

// MARK: - MaterialProvider  (your CAD/CSX bridge)

/// Bridge to your already-existing CAD infrastructure. This replaces the
/// ContinuousStructure / CSPropMaterial / CSPrimBox lookups the original
/// Operator performed directly against CSXCAD.
public protocol MaterialProvider: AnyObject {
    /// epsR, kappa, mueR, sigma, density at Cartesian-ish coord for direction ny (0=eps,1=kappa,2=mue,3=sigma,4=density handled via matType)
    func material(direction ny: Int, coords: (Double, Double, Double), matType: Int) -> Double

    /// Background (free-space or user-set) material fallback values
    var backgroundEpsR: Double { get }
    var backgroundMueR: Double { get }
    var backgroundKappa: Double { get }
    var backgroundSigma: Double { get }
    var backgroundDensity: Double { get }
}

// MARK: - Operator  (port of operator.h / operator.cpp core)

/// A graded, impedance-ratio-matched lossy layer near the domain boundary.
///
/// This is **not** a true PML: a real PML uses complex-frequency-shifted
/// coordinate stretching so a plane wave sees zero reflection at any angle
/// and frequency. This is the much older, simpler "resistive taper"
/// technique — an electric conductivity that ramps up smoothly over the last
/// `cellCount` cells before a boundary, with a magnetic loss set so the
/// layer's wave impedance stays close to the background (which is what
/// keeps normal-incidence reflection low). Oblique and low-frequency waves
/// still reflect more than they would from a real PML, but it is a large
/// improvement over a hard wall and is enough to identify a resonance in a
/// return-loss sweep.
public struct AbsorbingBoundarySettings {
    /// `[xMin, xMax, yMin, yMax, zMin, zMax]`; true = that face is absorbing.
    public var absorbingFaces: [Bool]
    public var cellCount: Int
    /// Grading exponent for the loss ramp (3 is the common PML default).
    public var gradingOrder: Double
    /// Electric conductivity [S/m] reached at the outermost cell, **per face**
    /// in the same order as `absorbingFaces`.
    ///
    /// Per face rather than one number for the whole domain because the
    /// optimum depends on the cell size *at that boundary*, and the six faces
    /// routinely differ: a board meshed finely through its substrate and
    /// coarsely out in the padding has cells an order of magnitude apart.
    public var maxElectricLossSPerM: [Double]

    public init(
        absorbingFaces: [Bool],
        cellCount: Int,
        gradingOrder: Double = 3,
        maxElectricLossSPerM: [Double]
    ) {
        precondition(absorbingFaces.count == 6)
        precondition(maxElectricLossSPerM.count == 6)
        self.absorbingFaces = absorbingFaces
        self.cellCount = max(0, cellCount)
        self.gradingOrder = gradingOrder
        self.maxElectricLossSPerM = maxElectricLossSPerM
    }
}

/// Grid + EC-coefficient generation for the Yee FDTD scheme.
/// Geometry-specific effective-material averaging is delegated to a
/// `MaterialProvider` (your CAD layer) instead of CSXCAD.
public final class Operator {

    public enum MatAverageMethod { case quarterCell, centralCell }
    public struct DebugFlags: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let none = DebugFlags([])
        public static let material = DebugFlags(rawValue: 1)
        public static let op       = DebugFlags(rawValue: 2)
        public static let pec      = DebugFlags(rawValue: 4)
    }

    // Grid
    public private(set) var discLines: [[Double]] = [[], [], []]   // main mesh lines per direction, drawing units
    public private(set) var numLines: (Int, Int, Int) = (0, 0, 0)
    public var gridDelta: Double = 1.0                              // drawing-unit -> meter scale

    // Background material
    public var backgroundEpsR: Double = 1.0
    public var backgroundMueR: Double = 1.0
    public var backgroundKappa: Double = 0.0
    public var backgroundSigma: Double = 0.0
    public var backgroundDensity: Double = 0.0

    /// Graded loss layer applied near the domain boundary; `nil` disables it.
    /// The layer only attenuates — what ends the domain behind it is the wall
    /// `applyElectricBC` or `applyMagneticBC` puts on that face.
    public var absorbingBoundary: AbsorbingBoundarySettings?

    /// Faces `[xMin, xMax, yMin, yMax, zMin, zMax]` set by `applyMagneticBC`.
    /// `Engine` reads these when it starts and images H across them.
    public private(set) var magneticWalls = [Bool](repeating: false, count: 6)

    /// A discrete two-terminal resistor stamped directly across a single Yee
    /// edge — used for a lumped port's source resistance. Its conductance
    /// (1/ohms) adds straight into that edge's G, alongside whatever the
    /// material provider contributes there.
    ///
    /// direction -> flatIndex -> total conductance [S] to add.
    private var lumpedResistorConductance: [Int: [Int: Double]] = [:]

    /// Registers a resistor of `ohms` across the Yee edge at `(direction,
    /// pos)`. Call before `calcECOperator()`. Safe to call more than once for
    /// the same edge (conductances add, as real parallel resistors would).
    public func addLumpedResistor(direction: Int, pos: (Int, Int, Int), ohms: Double) {
        guard ohms > 0 else { return }
        let i = flatIndex(pos)
        lumpedResistorConductance[direction, default: [:]][i, default: 0] += 1.0 / ohms
    }

    public var materialProvider: MaterialProvider?
    public var matAverageMethod: MatAverageMethod = .quarterCell

    // EC intermediate coefficients (per direction, flat over the mesh)
    private var EC_C: [[Double]] = [[], [], []]
    private var EC_G: [[Double]] = [[], [], []]
    private var EC_L: [[Double]] = [[], [], []]
    private var EC_R: [[Double]] = [[], [], []]
    /// Conductance from the *material* alone, without the absorbing layer or
    /// any lumped load. `calcPEC` must judge metal on the material only: the
    /// absorber and a port resistor both add large conductance, and treating
    /// either as metal would wall off the boundary or short out the port.
    private var EC_Gmaterial: [[Double]] = [[], [], []]

    /// Number of edges the last `calcPEC()` forced to perfect conductor.
    public private(set) var pecEdgeCount = 0

    /// Edges forced to perfect conductor regardless of what the material
    /// averaging found, as `(direction, position)`.
    ///
    /// This is how an infinitely thin conductor gets represented. Volumetric
    /// averaging samples cell interiors, so a surface of zero thickness is
    /// invisible to it however fine the mesh — it occupies no volume to
    /// average over. The standard treatment, and openEMS's, is to stop
    /// pretending it is a material at all and impose the boundary condition
    /// directly: tangential E vanishes on a perfect conductor, so the edges
    /// lying *in* the sheet's plane are zeroed.
    public var forcedPECEdges: [(direction: Int, pos: (Int, Int, Int))] = []

    // FDTD update coefficients consumed by Engine
    public private(set) var vv: FDTDArray!
    public private(set) var vi: FDTDArray!
    public private(set) var ii: FDTDArray!
    public private(set) var iv: FDTDArray!

    // per-position material storage (optional, for post-processing / debug dumps)
    public var storeMaterial: (epsR: Bool, kappa: Bool, mueR: Bool, sigma: Bool) = (false, false, false, false)
    private var m_epsR: FDTDArray?
    private var m_kappa: FDTDArray?
    private var m_mueR: FDTDArray?
    private var m_sigma: FDTDArray?

    // Timestep
    public private(set) var dT: Double = 0
    public var timeStepMethod: Int = 3   // 0=auto,1=CFL,3=Rennings (default, matches original)
    public var timeStepFactor: Double = 1.0
    public private(set) var timestepValid: Bool = true

    public init() {}

    // MARK: Grid setup (replacement for Operator::SetupCSXGrid)

    /// Feed the operator with mesh lines already produced by your CAD layer
    /// (equivalent to CSRectGrid::GetLines(...) in the original).
    public func setupGrid(discLines: [[Double]], gridDeltaUnit: Double) {
        precondition(discLines.count == 3)
        for n in 0..<3 {
            precondition(discLines[n].count >= 3, "need at least 3 disc-lines in every direction (3D!)")
        }
        self.discLines = discLines
        self.numLines = (discLines[0].count, discLines[1].count, discLines[2].count)
        self.gridDelta = gridDeltaUnit
        initOperatorStorage()
    }

    private func initOperatorStorage() {
        vv = FDTDArray(name: "vv", numLines: numLines)
        vi = FDTDArray(name: "vi", numLines: numLines)
        ii = FDTDArray(name: "ii", numLines: numLines)
        iv = FDTDArray(name: "iv", numLines: numLines)
    }

    public func initDataStorage() {
        if storeMaterial.epsR  { m_epsR  = FDTDArray(name: "m_epsR",  numLines: numLines) }
        if storeMaterial.kappa { m_kappa = FDTDArray(name: "m_kappa", numLines: numLines) }
        if storeMaterial.mueR  { m_mueR  = FDTDArray(name: "m_mueR",  numLines: numLines) }
        if storeMaterial.sigma { m_sigma = FDTDArray(name: "m_sigma", numLines: numLines) }
    }

    // MARK: Disc line / geometry helpers (GetDiscLine, GetDiscDelta, GetEdgeLength, ...)

    /// Positions one cell outside the domain (as the quarter-cell averaging's
    /// quadrant shifts can request at the very first/last line) are clamped
    /// to the boundary line rather than indexed out of range — equivalent to
    /// extending the outermost cell, a standard, harmless simplification at
    /// a domain edge that is about to be PML/PEC/PMC terminated anyway.
    public func getDiscLine(_ n: Int, _ pos: Int, dualMesh: Bool = false) -> Double {
        guard n >= 0 && n <= 2 else { return 0.0 }
        let count = numLinesFor(n)
        guard count > 0 else { return 0.0 }
        let clamped = min(max(pos, 0), count - 1)
        if !dualMesh { return discLines[n][clamped] }
        if clamped < count - 1 {
            return 0.5 * (discLines[n][clamped] + discLines[n][clamped + 1])
        }
        guard count > 1 else { return discLines[n][clamped] }
        return discLines[n][clamped] + 0.5 * (discLines[n][clamped] - discLines[n][clamped - 1])
    }

    public func getDiscDelta(_ n: Int, _ pos: Int, dualMesh: Bool = false) -> Double {
        guard n >= 0 && n <= 2, pos < numLinesFor(n) else { return 0.0 }
        if !dualMesh {
            // The *primary* edge: node pos to node pos+1. Deriving it from
            // dual lines instead returns the dual spacing at pos+1 — the same
            // number on a uniform mesh, and badly wrong on a graded one.
            //
            // Clamped the way `getDiscLine` clamps, because quarter-cell
            // averaging legitimately asks for `pos − 1` at the first line: a
            // position off the end extends the outermost cell rather than
            // indexing out of range.
            let count = numLinesFor(n)
            guard count > 1 else { return 0.0 }
            let start = Swift.min(Swift.max(pos, 0), count - 2)
            return discLines[n][start + 1] - discLines[n][start]
        } else {
            if pos > 0 {
                return getDiscLine(n, pos, dualMesh: true) - getDiscLine(n, pos - 1, dualMesh: true)
            } else {
                return getDiscLine(n, 1, dualMesh: false) - getDiscLine(n, 0, dualMesh: false)
            }
        }
    }

    public func getEdgeLength(_ n: Int, _ pos: (Int, Int, Int), dualMesh: Bool = false) -> Double {
        getDiscDelta(n, component(pos, n), dualMesh: dualMesh) * gridDelta
    }

    public func getNodeWidth(_ ny: Int, _ pos: (Int, Int, Int), dualMesh: Bool = false) -> Double {
        getEdgeLength(ny, pos, dualMesh: !dualMesh)
    }

    public func getNodeArea(_ ny: Int, _ pos: (Int, Int, Int), dualMesh: Bool = false) -> Double {
        let nyP = (ny + 1) % 3
        let nyPP = (ny + 2) % 3
        return getNodeWidth(nyP, pos, dualMesh: dualMesh) * getNodeWidth(nyPP, pos, dualMesh: dualMesh)
    }

    public func getEdgeArea(_ ny: Int, _ pos: (Int, Int, Int), dualMesh: Bool = false) -> Double {
        getNodeArea(ny, pos, dualMesh: dualMesh)
    }

    public func getCellVolume(_ pos: (Int, Int, Int), dualMesh: Bool = false) -> Double {
        (0..<3).reduce(1.0) { $0 * getEdgeLength($1, pos, dualMesh: dualMesh) }
    }

    private func numLinesFor(_ n: Int) -> Int { n == 0 ? numLines.0 : (n == 1 ? numLines.1 : numLines.2) }
    private func component(_ pos: (Int, Int, Int), _ n: Int) -> Int { n == 0 ? pos.0 : (n == 1 ? pos.1 : pos.2) }

    // MARK: EC computation (Init_EC, Calc_EC, Calc_ECOperatorPos, CalcECOperator)

    /// Port of Operator::Init_EC()
    private func initEC() {
        let size = numLines.0 * numLines.1 * numLines.2
        for n in 0..<3 {
            EC_C[n] = [Double](repeating: 0, count: size)
            EC_G[n] = [Double](repeating: 0, count: size)
            EC_L[n] = [Double](repeating: 0, count: size)
            EC_R[n] = [Double](repeating: 0, count: size)
            EC_Gmaterial[n] = [Double](repeating: 0, count: size)
        }
    }

    @inline(__always)
    private func flatIndex(_ pos: (Int, Int, Int)) -> Int {
        (pos.0 * numLines.1 + pos.1) * numLines.2 + pos.2
    }

    /// Port of Operator::Calc_ECPos: effective material -> C,G,L,R at an edge.
    /// This is where your CAD/material provider is consulted (was CSX lookup).
    private func calcECPos(
        direction ny: Int,
        pos: (Int, Int, Int)
    ) -> (C: Double, G: Double, L: Double, R: Double, materialG: Double) {
        let effMat = calcEffMatPos(direction: ny, pos: pos)

        if let m_epsR { m_epsR.set(ny, pos, effMat.eps) }
        if let m_kappa { m_kappa.set(ny, pos, effMat.kappa) }
        if let m_mueR { m_mueR.set(ny, pos, effMat.mue) }
        if let m_sigma { m_sigma.set(ny, pos, effMat.sigma) }

        let delta1 = getEdgeLength(ny, pos)
        let area1  = getEdgeArea(ny, pos)
        let C = delta1 != 0 ? effMat.eps   * area1 / delta1 : 0
        var G = delta1 != 0 ? effMat.kappa * area1 / delta1 : 0

        let delta2 = getEdgeLength(ny, pos, dualMesh: true)
        let area2  = getEdgeArea(ny, pos, dualMesh: true)
        let L = delta2 != 0 ? effMat.mue   * area2 / delta2 : 0
        var R = delta2 != 0 ? effMat.sigma * area2 / delta2 : 0

        let materialG = G

        let absorbingSigmaE = absorbingLoss(direction: ny, pos: pos)
        if absorbingSigmaE > 0 {
            if delta1 != 0 { G += absorbingSigmaE * area1 / delta1 }
            // Matched-layer condition in the *local* medium: σ_m/µ = σ_e/ε.
            // Using vacuum's µ0/ε0 regardless, as this did, leaves the layer
            // mismatched everywhere a dielectric reaches the boundary — and a
            // substrate usually does, since it runs to the domain edge.
            if delta2 != 0, effMat.eps > 0 {
                let sigmaM = absorbingSigmaE * effMat.mue / effMat.eps
                R += sigmaM * area2 / delta2
            }
        }

        // A literal two-terminal resistor across this exact edge contributes
        // its conductance (1/ohms) directly — no area/length scaling, unlike
        // a material's per-unit-length kappa.
        if let extra = lumpedResistorConductance[ny]?[flatIndex(pos)] {
            G += extra
        }

        return (C, G, L, R, materialG)
    }

    /// Graded electric/magnetic loss from `absorbingBoundary`, evaluated at
    /// one Yee edge. The magnetic loss is scaled by µ0/ε0 relative to the
    /// electric one (the classic loss-matching condition) so the layer's
    /// wave impedance stays close to free space, keeping normal-incidence
    /// reflection low despite this not being a true PML.
    /// Electric conductivity of the absorbing layer at one edge, S/m.
    ///
    /// The magnetic counterpart is *not* returned: the matched-layer condition
    /// is `σ_m = σ_e · µ/ε` in the **local** medium, and the local ε and µ are
    /// only known where the effective material has been averaged. Returning a
    /// magnetic loss computed from vacuum here is what made the layer
    /// mismatched wherever a substrate ran into it.
    private func absorbingLoss(direction: Int, pos: (Int, Int, Int)) -> Double {
        guard let settings = absorbingBoundary, settings.cellCount > 0 else { return 0 }

        var sigmaE = 0.0
        let coords = [pos.0, pos.1, pos.2]
        for dim in 0..<3 {
            let count = numLinesFor(dim)
            let distanceFromMin = coords[dim]
            let distanceFromMax = count - 1 - coords[dim]

            // Each face carries its own peak conductivity, so the ramp is
            // scaled by that face's optimum rather than a domain-wide one.
            if settings.absorbingFaces[2 * dim], distanceFromMin < settings.cellCount {
                let x = Double(settings.cellCount - distanceFromMin) / Double(settings.cellCount)
                sigmaE = max(sigmaE, settings.maxElectricLossSPerM[2 * dim] * pow(x, settings.gradingOrder))
            }
            if settings.absorbingFaces[2 * dim + 1], distanceFromMax < settings.cellCount {
                let x = Double(settings.cellCount - distanceFromMax) / Double(settings.cellCount)
                sigmaE = max(sigmaE, settings.maxElectricLossSPerM[2 * dim + 1] * pow(x, settings.gradingOrder))
            }
        }
        return sigmaE
    }

    /// Port of Operator::Calc_EffMatPos -> dispatches to quarter-cell / cell-center averaging
    private func calcEffMatPos(direction ny: Int, pos: (Int, Int, Int)) -> (eps: Double, kappa: Double, mue: Double, sigma: Double) {
        switch matAverageMethod {
        case .quarterCell:  return averageMatQuarterCell(direction: ny, pos: pos)
        case .centralCell:  return averageMatCellCenter(direction: ny, pos: pos)
        }
    }

    private func material(_ direction: Int, _ coords: (Double, Double, Double), _ matType: Int) -> Double {
        if let mp = materialProvider {
            return mp.material(direction: direction, coords: coords, matType: matType)
        }
        switch matType {
        case 0: return backgroundEpsR
        case 1: return backgroundKappa
        case 2: return backgroundMueR
        case 3: return backgroundSigma
        default: return backgroundDensity
        }
    }

    /// Port of Operator::AverageMatCellCenter
    private func averageMatCellCenter(direction ny: Int, pos: (Int, Int, Int)) -> (eps: Double, kappa: Double, mue: Double, sigma: Double) {
        let n = ny, nP = (ny + 1) % 3, nPP = (ny + 2) % 3
        var loc = [pos.0, pos.1, pos.2]

        var eps = 0.0, kappa = 0.0, area = 0.0

        func coordAt(_ p: [Int]) -> (Double, Double, Double)? {
            for k in 0..<3 where p[k] < 0 || p[k] >= numLinesFor(k) { return nil }
            let c0 = getDiscLine(0, p[0], dualMesh: true)
            let c1 = getDiscLine(1, p[1], dualMesh: true)
            let c2 = getDiscLine(2, p[2], dualMesh: true)
            return (c0, c1, c2)
        }

        // 4 quadrants around the edge midpoint (up-right, up-left, down-right, down-left)
        let quadrantShifts: [(Int, Int)] = [(0, 0), (-1, 0), (0, -1), (-1, -1)]
        var running = [pos.0, pos.1, pos.2]
        for (dP, dPP) in quadrantShifts {
            running = [pos.0, pos.1, pos.2]
            running[nP] += dP
            running[nPP] += dPP
            if let c = coordAt(running) {
                let A = getNodeArea(ny, (running[0], running[1], running[2]), dualMesh: true)
                eps   += material(n, c, 0) * A
                kappa += material(n, c, 1) * A
                area  += A
            }
        }
        if area > 0 { eps = eps * FDTDConstants.EPS0 / area; kappa /= area } else { eps = 0; kappa = 0 }

        // mu, sigma averaging along the n-direction (down / up neighbours)
        var mueAcc = 0.0, sigmaAcc = 0.0, length = 0.0
        loc = [pos.0, pos.1, pos.2]
        for dn in [-1, 1] {
            loc = [pos.0, pos.1, pos.2]
            loc[n] += dn
            if let c = coordAt(loc) {
                let deltaNy = getNodeWidth(n, (loc[0], loc[1], loc[2]), dualMesh: true)
                let muVal = material(n, c, 2)
                if muVal != 0 { mueAcc += deltaNy / muVal }
                let sigmaVal = material(n, c, 3)
                if sigmaVal != 0 { sigmaAcc += deltaNy / sigmaVal } else { sigmaAcc = 0 }
                length += deltaNy
            }
        }
        let mue = mueAcc > 0 ? length * FDTDConstants.MUE0 / mueAcc : FDTDConstants.MUE0
        let sigma = sigmaAcc > 0 ? length / sigmaAcc : 0

        return (eps, kappa, mue, sigma)
    }

    /// Port of Operator::AverageMatQuarterCell (default averaging method)
    private func averageMatQuarterCell(direction ny: Int, pos: (Int, Int, Int)) -> (eps: Double, kappa: Double, mue: Double, sigma: Double) {
        let n = ny, nP = (ny + 1) % 3, nPP = (ny + 2) % 3

        func rawDelta(_ dim: Int, _ p: Int) -> Double {
            let N = numLinesFor(dim)
            if p < 0 { return discLines[dim][0] - discLines[dim][1] }
            if p >= N - 1 { return discLines[dim][N - 2] - discLines[dim][N - 1] }
            return discLines[dim][p + 1] - discLines[dim][p]
        }

        let coord0 = discLines[0][pos.0], coord1 = discLines[1][pos.1], coord2 = discLines[2][pos.2]
        var coord = [coord0, coord1, coord2]

        let delta   = rawDelta(n, component(pos, n))
        let deltaP  = rawDelta(nP, component(pos, nP))
        let deltaPP = rawDelta(nPP, component(pos, nPP))
        let deltaM   = rawDelta(n, component(pos, n) - 1)
        let deltaPM  = rawDelta(nP, component(pos, nP) - 1)
        let deltaPPM = rawDelta(nPP, component(pos, nPP) - 1)

        var eps = 0.0, kappa = 0.0, area = 0.0
        var loc = [pos.0, pos.1, pos.2]

        func areaAt(_ p: [Int]) -> Double { getNodeArea(ny, (p[0], p[1], p[2]), dualMesh: true) }

        // up-right
        coord = [coord0, coord1, coord2]
        coord[n] += delta * 0.5; coord[nP] += deltaP * 0.25; coord[nPP] += deltaPP * 0.25
        loc = [pos.0, pos.1, pos.2]
        var A = areaAt(loc)
        eps = material(n, (coord[0], coord[1], coord[2]), 0) * A
        kappa = material(n, (coord[0], coord[1], coord[2]), 1) * A
        area += A

        // up-left
        coord = [coord0, coord1, coord2]
        coord[n] += delta * 0.5; coord[nP] -= deltaPM * 0.25; coord[nPP] += deltaPP * 0.25
        loc[nP] -= 1
        A = areaAt(loc)
        eps += material(n, (coord[0], coord[1], coord[2]), 0) * A
        kappa += material(n, (coord[0], coord[1], coord[2]), 1) * A
        area += A

        // down-right
        coord = [coord0, coord1, coord2]
        coord[n] += delta * 0.5; coord[nP] += deltaP * 0.25; coord[nPP] -= deltaPPM * 0.25
        loc[nP] += 1; loc[nPP] -= 1
        A = areaAt(loc)
        eps += material(n, (coord[0], coord[1], coord[2]), 0) * A
        kappa += material(n, (coord[0], coord[1], coord[2]), 1) * A
        area += A

        // down-left
        coord = [coord0, coord1, coord2]
        coord[n] += delta * 0.5; coord[nP] -= deltaPM * 0.25; coord[nPP] -= deltaPPM * 0.25
        loc[nP] -= 1
        A = areaAt(loc)
        eps += material(n, (coord[0], coord[1], coord[2]), 0) * A
        kappa += material(n, (coord[0], coord[1], coord[2]), 1) * A
        area += A

        eps = area > 0 ? eps * FDTDConstants.EPS0 / area : 0
        kappa = area > 0 ? kappa / area : 0

        // mu, sigma along n
        var mueAcc = 0.0, sigmaAcc = 0.0, length = 0.0
        var locN = [pos.0, pos.1, pos.2]

        // shift down
        coord = [coord0, coord1, coord2]
        coord[n] -= deltaM * 0.25; coord[nP] += deltaP * 0.5; coord[nPP] += deltaPP * 0.5
        locN[n] -= 1
        var deltaNy = getNodeWidth(n, (locN[0], locN[1], locN[2]), dualMesh: true)
        let mu0 = material(n, (coord[0], coord[1], coord[2]), 2)
        mueAcc = mu0 != 0 ? deltaNy / mu0 : 0
        let sig0 = material(n, (coord[0], coord[1], coord[2]), 3)
        sigmaAcc = sig0 != 0 ? deltaNy / sig0 : 0
        length = deltaNy

        // shift up
        coord = [coord0, coord1, coord2]
        coord[n] += delta * 0.25; coord[nP] += deltaP * 0.5; coord[nPP] += deltaPP * 0.5
        locN = [pos.0, pos.1, pos.2]
        locN[n] += 1
        deltaNy = getNodeWidth(n, (locN[0], locN[1], locN[2]), dualMesh: true)
        let mu1 = material(n, (coord[0], coord[1], coord[2]), 2)
        if mu1 != 0 { mueAcc += deltaNy / mu1 }
        let sig1 = material(n, (coord[0], coord[1], coord[2]), 3)
        if sig1 != 0 { sigmaAcc += deltaNy / sig1 } else { sigmaAcc = 0 }
        length += deltaNy

        let mue = mueAcc > 0 ? length * FDTDConstants.MUE0 / mueAcc : FDTDConstants.MUE0
        let sigma = sigmaAcc > 0 ? length / sigmaAcc : 0

        return (eps, kappa, mue, sigma)
    }

    /// Port of Operator::Calc_ECOperatorPos: converts C,G,L,R into VV/VI/II/IV
    private func calcECOperatorPos(_ n: Int, _ pos: (Int, Int, Int)) {
        let i = flatIndex(pos)
        let C = EC_C[n][i], G = EC_G[n][i]
        if C > 0 {
            vv.set(n, pos, (1.0 - dT * G / 2.0 / C) / (1.0 + dT * G / 2.0 / C))
            vi.set(n, pos, (dT / C) / (1.0 + dT * G / 2.0 / C))
        } else {
            vv.set(n, pos, 0); vi.set(n, pos, 0)
        }

        let L = EC_L[n][i], R = EC_R[n][i]
        if L > 0 {
            ii.set(n, pos, (1.0 - dT * R / 2.0 / L) / (1.0 + dT * R / 2.0 / L))
            iv.set(n, pos, (dT / L) / (1.0 + dT * R / 2.0 / L))
        } else {
            ii.set(n, pos, 0); iv.set(n, pos, 0)
        }
    }

    /// Port of Operator::Calc_EC / Calc_EC_Range
    private func calcEC() {
        for x in 0..<numLines.0 {
            for y in 0..<numLines.1 {
                for z in 0..<numLines.2 {
                    let pos = (x, y, z)
                    let i = flatIndex(pos)
                    for n in 0..<3 {
                        let ec = calcECPos(direction: n, pos: pos)
                        EC_C[n][i] = ec.C
                        EC_G[n][i] = ec.G
                        EC_L[n][i] = ec.L
                        EC_R[n][i] = ec.R
                        EC_Gmaterial[n][i] = ec.materialG
                    }
                }
            }
        }
    }

    /// Port of Operator::CalcECOperator — the master routine tying everything
    /// together: EC->VV/VI/II/IV, timestep, boundary conditions.
    @discardableResult
    public func calcECOperator(debug: DebugFlags = .none) -> Int {
        initEC()
        initDataStorage()
        calcEC()

        timestepValid = false
        if dT > 0 {
            let saveDT = dT
            _ = calcTimestep()
            if dT > saveDT { dT = saveDT } else { timestepValid = true }
        } else {
            _ = calcTimestep()
        }

        initOperatorStorage()

        for n in 0..<3 {
            for x in 0..<numLines.0 {
                for y in 0..<numLines.1 {
                    for z in 0..<numLines.2 {
                        calcECOperatorPos(n, (x, y, z))
                    }
                }
            }
        }

        calcPEC()
        zeroEdgesLeavingDomain()

        // release EC scratch buffers, matches original cleanup
        for n in 0..<3 {
            EC_C[n] = []; EC_G[n] = []; EC_L[n] = []; EC_R[n] = []; EC_Gmaterial[n] = []
        }

        return 0
    }

    /// Beyond this the semi-implicit voltage coefficient turns negative.
    ///
    /// `vv = (1 - x)/(1 + x)` with `x = dT·G/2C` approximates the true decay
    /// `exp(-2x)`, and does it well while `x` is small. At `x = 1` it reaches
    /// zero, and past that it goes *negative* — the field would invert every
    /// timestep instead of being absorbed, which no passive lossy medium can
    /// do. A material that lossy is a conductor, and perfect conductor is the
    /// only valid limit.
    static let pecLossThreshold = 1.0

    /// Port of `Operator::CalcPEC()` — zero the voltage operator on edges
    /// inside metal.
    ///
    /// openEMS finds these by asking CSX for a METAL property at the edge.
    /// This model has no separate metal property; it expresses metal as a
    /// conductivity, so the same edges are identified numerically, by the
    /// point at which the update can no longer represent the loss.
    ///
    /// Without this pass a copper or PEC edge got `vv = -0.999999` instead of
    /// `0`: the field inverted and persisted rather than being annihilated,
    /// making every conductor in the model a spurious resonator and shifting
    /// resonant frequencies well outside the mesh error.
    @discardableResult
    public func calcPEC() -> Int {
        var count = 0
        for n in 0..<3 {
            for x in 0..<numLines.0 {
                for y in 0..<numLines.1 {
                    for z in 0..<numLines.2 {
                        let pos = (x, y, z)
                        let i = flatIndex(pos)
                        let C = EC_C[n][i]
                        guard C > 0 else { continue }
                        let G = EC_Gmaterial[n][i]
                        guard G > 0, dT * G / (2 * C) >= Self.pecLossThreshold else { continue }
                        vv.set(n, pos, 0)
                        vi.set(n, pos, 0)
                        count += 1
                    }
                }
            }
        }

        // Zero-thickness conductors, which the material path cannot see.
        for edge in forcedPECEdges {
            guard edge.direction >= 0, edge.direction < 3 else { continue }
            guard edge.pos.0 >= 0, edge.pos.0 < numLines.0,
                  edge.pos.1 >= 0, edge.pos.1 < numLines.1,
                  edge.pos.2 >= 0, edge.pos.2 < numLines.2 else { continue }
            vv.set(edge.direction, edge.pos, 0)
            vi.set(edge.direction, edge.pos, 0)
            count += 1
        }

        pecEdgeCount = count
        return count
    }

    // MARK: Timestep (Rennings dissertation, variant 1 / 3 — CalcTimestep_Var1)

    public func setTimestep(_ ts: Double) { dT = ts }
    public func setTimestepFactor(_ factor: Double) {
        guard factor > 0, factor <= 1 else { return }
        timeStepFactor = factor
    }

    /// Port of Operator::CalcTimestep -> dispatches to Var1 (Rennings) by default
    @discardableResult
    private func calcTimestep() -> Double {
        return calcTimestepVar1()
    }

    /// Port of Operator::CalcTimestep_Var1
    /// Rennings' dissertation (2008), p.66, formula 4.52 — CFL-like bound
    /// derived directly from the per-edge L/C equivalent-circuit parameters.
    private func calcTimestepVar1() -> Double {
        var best = Double.greatestFiniteMagnitude

        for n in 0..<3 {
            let nP = (n + 1) % 3
            let nPP = (n + 2) % 3
            for x in 0..<numLines.0 {
                for y in 0..<numLines.1 {
                    for z in 0..<numLines.2 {
                        let pos = (x, y, z)
                        let i = flatIndex(pos)

                        var posPM = [pos.0, pos.1, pos.2]; posPM[nP] -= 1
                        var posPPM = [pos.0, pos.1, pos.2]; posPPM[nPP] -= 1
                        guard posPM[nP] >= 0, posPPM[nPP] >= 0 else { continue }

                        let iPM = flatIndex((posPM[0], posPM[1], posPM[2]))
                        let iPPM = flatIndex((posPPM[0], posPPM[1], posPPM[2]))

                        let LnP = EC_L[nP][i], LnPatPPM = EC_L[nP][iPPM]
                        let LnPP = EC_L[nPP][i], LnPPatPM = EC_L[nPP][iPM]
                        let Cn = EC_C[n][i]

                        guard LnP > 0, LnPatPPM > 0, LnPP > 0, LnPPatPM > 0, Cn > 0 else { continue }

                        let denom = (4 / LnP + 4 / LnPatPPM + 4 / LnPP + 4 / LnPPatPM) / Cn
                        guard denom > 0 else { continue }
                        let candidate = 2.0 / sqrt(denom)
                        if candidate < best && candidate > 0 { best = candidate }
                    }
                }
            }
        }

        if best == Double.greatestFiniteMagnitude { best = 0 }
        dT = best * timeStepFactor
        return dT
    }

    // MARK: Boundary conditions (ApplyElectricBC / ApplyMagneticBC)

    /// Electric walls: tangential E vanishes on each flagged face.
    ///
    /// `dirs` has 6 entries, `[xMin, xMax, yMin, yMax, zMin, zMax]`. The two
    /// field components lying in a face are zeroed on its outermost grid
    /// line, so the wall sits exactly on that line on either side.
    ///
    /// This used to zero the component *normal* to the face — the one E field
    /// a conductor leaves alone. Tangential E was then decided by the engine's
    /// bare edges instead, always zero on a lower face and never on an upper
    /// one, and a lower face asked to be a wall also lost the normal field in
    /// its first layer of cells.
    public func applyElectricBC(_ dirs: [Bool]) {
        guard dirs.count == 6 else { return }
        for face in 0..<6 where dirs[face] {
            let axis = face / 2
            let plane = face % 2 == 0 ? 0 : numLinesFor(axis) - 1
            for component in [(axis + 1) % 3, (axis + 2) % 3] {
                forEachPosition(onPlane: plane, of: axis) { pos in
                    vv.set(component, pos, 0)
                    vi.set(component, pos, 0)
                }
            }
        }
    }

    /// Magnetic walls: tangential H vanishes on each flagged face.
    ///
    /// Tangential H lives half a cell off every grid line, so there is no
    /// coefficient to zero that would put a magnetic wall *on* one. The engine
    /// images H across the face instead — odd, where an electric wall's image
    /// is even — which places the wall on the outermost line exactly as
    /// `applyElectricBC` does. That makes a magnetic wall an exact symmetry
    /// plane: half a model closed by one reproduces the whole model's fields.
    ///
    /// Only records the faces, which `Engine` reads when it starts, so call it
    /// before `Engine.make(op:)`. A face must not also be passed to
    /// `applyElectricBC`, which would pin the field this leaves free.
    public func applyMagneticBC(_ dirs: [Bool]) {
        guard dirs.count == 6 else { return }
        magneticWalls = dirs
    }

    /// Calls `body` with every grid position on plane `index` of `axis`.
    private func forEachPosition(onPlane index: Int, of axis: Int, _ body: ((Int, Int, Int)) -> Void) {
        let first = (axis + 1) % 3, second = (axis + 2) % 3
        for a in 0..<numLinesFor(first) {
            for b in 0..<numLinesFor(second) {
                var pos = [0, 0, 0]
                pos[axis] = index
                pos[first] = a
                pos[second] = b
                body((pos[0], pos[1], pos[2]))
            }
        }
    }

    /// Zeroes every E edge that starts on the last grid line of its own axis.
    ///
    /// Such an edge ends one line beyond the domain. Nothing drives it while
    /// the H outside stays zero, but a magnetic wall's image makes that H live,
    /// so the edge is shut off explicitly — as openEMS does.
    private func zeroEdgesLeavingDomain() {
        for n in 0..<3 {
            forEachPosition(onPlane: numLinesFor(n) - 1, of: n) { pos in
                vv.set(n, pos, 0)
                vi.set(n, pos, 0)
            }
        }
    }

    // MARK: Access for Engine

    @inline(__always) public func getVV(_ n: Int, _ x: Int, _ y: Int, _ z: Int) -> FDTDFloat { vv.get(n, x, y, z) }
    @inline(__always) public func getVI(_ n: Int, _ x: Int, _ y: Int, _ z: Int) -> FDTDFloat { vi.get(n, x, y, z) }
    @inline(__always) public func getII(_ n: Int, _ x: Int, _ y: Int, _ z: Int) -> FDTDFloat { ii.get(n, x, y, z) }
    @inline(__always) public func getIV(_ n: Int, _ x: Int, _ y: Int, _ z: Int) -> FDTDFloat { iv.get(n, x, y, z) }

    /// Hook for your CAD/extension system to inject EngineExtension instances
    /// (PML, excitation, lumped elements, ...). Wire this to your existing
    /// Operator_Extension-equivalent registry.
    public var extensionFactories: [() -> EngineExtension] = []
    func makeEngineExtensions() -> [EngineExtension] {
        extensionFactories.map { $0() }
    }

    public func getNumberOfLines(_ ny: Int, full: Bool = false) -> Int {
        numLinesFor(ny)
    }
}