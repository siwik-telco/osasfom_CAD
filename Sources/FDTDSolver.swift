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
/// Storage layout: idx = ((n*nx + x)*ny + y)*nz + z
public final class FDTDArray {
    public let name: String
    public let numLines: (Int, Int, Int)
    private var data: [FDTDFloat]

    public init(name: String, numLines: (Int, Int, Int)) {
        self.name = name
        self.numLines = numLines
        let count = 3 * numLines.0 * numLines.1 * numLines.2
        self.data = [FDTDFloat](repeating: 0, count: count)
    }

    @inline(__always)
    private func index(_ n: Int, _ x: Int, _ y: Int, _ z: Int) -> Int {
        ((n * numLines.0 + x) * numLines.1 + y) * numLines.2 + z
    }

    @inline(__always)
    public func get(_ n: Int, _ x: Int, _ y: Int, _ z: Int) -> FDTDFloat {
        data[index(n, x, y, z)]
    }

    @inline(__always)
    public func set(_ n: Int, _ x: Int, _ y: Int, _ z: Int, _ value: FDTDFloat) {
        data[index(n, x, y, z)] = value
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
        for i in data.indices { data[i] = value }
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
    }

    public func initEngine() {
        numTS = 0
        volt = FDTDArray(name: "volt", numLines: numLines)
        curr = FDTDArray(name: "curr", numLines: numLines)
        initExtensions()
        sortExtensionsByPriority()
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

    /// Port of Engine::UpdateVoltages(startX, numX)
    /// Advances the electric field ("volt", E on Yee edges) using curl(H).
    public func updateVoltages(startX: Int, numX: Int) {
        let (nx, ny, nz) = numLines
        var pos = (x: startX, y: 0, z: 0)

        for _ in 0..<numX {
            for y in 0..<ny {
                pos.y = y
                for z in 0..<nz {
                    pos.z = z
                    for n in 0..<3 {
                        let nP  = (n + 1) % 3
                        let nPP = (n + 2) % 3

                        let shiftP:  Int = componentIndex(pos, nP)  > 0 ? 1 : 0
                        let shiftPP: Int = componentIndex(pos, nPP) > 0 ? 1 : 0

                        let posP  = shifted(pos, dim: nP,  by: -shiftP)
                        let posPP = shifted(pos, dim: nPP, by: -shiftPP)

                        let curl = curr.get(nPP, pos) - curr.get(nPP, posP)
                                 - curr.get(nP,  pos) + curr.get(nP,  posPP)

                        let vv = op.getVV(n, pos.x, pos.y, pos.z)
                        let vi = op.getVI(n, pos.x, pos.y, pos.z)

                        let newV = vv * volt.get(n, pos) + vi * curl
                        volt.set(n, pos, newV)
                    }
                }
            }
            pos.x += 1
        }
    }

    /// Port of Engine::UpdateCurrents(startX, numX)
    /// Advances the magnetic field ("curr", H on Yee faces) using curl(E).
    public func updateCurrents(startX: Int, numX: Int) {
        let (nx, ny, nz) = numLines
        var pos = (x: startX, y: 0, z: 0)

        for _ in 0..<numX {
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
            pos.x += 1
        }
        _ = nx // silence unused warning when nx unused directly
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
            doPostCurrentUpdates()
            apply2Current()

            numTS += 1
        }
        return true
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

    public var materialProvider: MaterialProvider?
    public var matAverageMethod: MatAverageMethod = .quarterCell

    // EC intermediate coefficients (per direction, flat over the mesh)
    private var EC_C: [[Double]] = [[], [], []]
    private var EC_G: [[Double]] = [[], [], []]
    private var EC_L: [[Double]] = [[], [], []]
    private var EC_R: [[Double]] = [[], [], []]

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

    public func getDiscLine(_ n: Int, _ pos: Int, dualMesh: Bool = false) -> Double {
        guard n >= 0 && n <= 2, pos < numLinesFor(n) else { return 0.0 }
        if !dualMesh { return discLines[n][pos] }
        if pos < numLinesFor(n) - 1 {
            return 0.5 * (discLines[n][pos] + discLines[n][pos + 1])
        }
        return discLines[n][pos] + 0.5 * (discLines[n][pos] - discLines[n][pos - 1])
    }

    public func getDiscDelta(_ n: Int, _ pos: Int, dualMesh: Bool = false) -> Double {
        guard n >= 0 && n <= 2, pos < numLinesFor(n) else { return 0.0 }
        if !dualMesh {
            if pos < numLinesFor(n) - 1 {
                return getDiscLine(n, pos + 1, dualMesh: true) - getDiscLine(n, pos, dualMesh: true)
            } else {
                return getDiscLine(n, pos, dualMesh: true) - getDiscLine(n, pos - 1, dualMesh: true)
            }
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
        }
    }

    @inline(__always)
    private func flatIndex(_ pos: (Int, Int, Int)) -> Int {
        (pos.0 * numLines.1 + pos.1) * numLines.2 + pos.2
    }

    /// Port of Operator::Calc_ECPos: effective material -> C,G,L,R at an edge.
    /// This is where your CAD/material provider is consulted (was CSX lookup).
    private func calcECPos(direction ny: Int, pos: (Int, Int, Int)) -> (C: Double, G: Double, L: Double, R: Double) {
        let effMat = calcEffMatPos(direction: ny, pos: pos)

        if let m_epsR { m_epsR.set(ny, pos, effMat.eps) }
        if let m_kappa { m_kappa.set(ny, pos, effMat.kappa) }
        if let m_mueR { m_mueR.set(ny, pos, effMat.mue) }
        if let m_sigma { m_sigma.set(ny, pos, effMat.sigma) }

        let delta1 = getEdgeLength(ny, pos)
        let area1  = getEdgeArea(ny, pos)
        let C = delta1 != 0 ? effMat.eps   * area1 / delta1 : 0
        let G = delta1 != 0 ? effMat.kappa * area1 / delta1 : 0

        let delta2 = getEdgeLength(ny, pos, dualMesh: true)
        let area2  = getEdgeArea(ny, pos, dualMesh: true)
        let L = delta2 != 0 ? effMat.mue   * area2 / delta2 : 0
        let R = delta2 != 0 ? effMat.sigma * area2 / delta2 : 0

        return (C, G, L, R)
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

        // release EC scratch buffers, matches original cleanup
        for n in 0..<3 { EC_C[n] = []; EC_G[n] = []; EC_L[n] = []; EC_R[n] = [] }

        return 0
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

    /// Port of Operator::ApplyElectricBC — zero tangential E on PEC boundaries.
    /// `dirs` has 6 entries: [xmin,xmax,ymin,ymax,zmin,zmax]; true = PEC there.
    public func applyElectricBC(_ dirs: [Bool]) {
        guard dirs.count == 6 else { return }
        for n in 0..<3 {
            let nP = (n + 1) % 3, nPP = (n + 2) % 3
            for a in 0..<numLinesFor(nP) {
                for b in 0..<numLinesFor(nPP) {
                    var pos = [0, 0, 0]
                    pos[nP] = a; pos[nPP] = b

                    if dirs[2 * n] {          // lower boundary in dir n
                        pos[n] = 0
                        vv.set(n, (pos[0], pos[1], pos[2]), 0)
                        vi.set(n, (pos[0], pos[1], pos[2]), 0)
                    }
                    if dirs[2 * n + 1] {      // upper boundary in dir n
                        pos[n] = numLinesFor(n) - 1
                        vv.set(n, (pos[0], pos[1], pos[2]), 0)
                        vi.set(n, (pos[0], pos[1], pos[2]), 0)
                    }
                }
            }
        }
    }

    /// Port of Operator::ApplyMagneticBC — zero tangential H on PMC boundaries.
    public func applyMagneticBC(_ dirs: [Bool]) {
        guard dirs.count == 6 else { return }
        for n in 0..<3 {
            let nP = (n + 1) % 3, nPP = (n + 2) % 3
            for a in 0..<numLinesFor(nP) {
                for b in 0..<numLinesFor(nPP) {
                    var pos = [0, 0, 0]
                    pos[nP] = a; pos[nPP] = b

                    if dirs[2 * n] {
                        pos[n] = 0
                        ii.set(n, (pos[0], pos[1], pos[2]), 0)
                        iv.set(n, (pos[0], pos[1], pos[2]), 0)
                    }
                    if dirs[2 * n + 1] {
                        pos[n] = numLinesFor(n) - 1
                        ii.set(n, (pos[0], pos[1], pos[2]), 0)
                        iv.set(n, (pos[0], pos[1], pos[2]), 0)
                    }
                }
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