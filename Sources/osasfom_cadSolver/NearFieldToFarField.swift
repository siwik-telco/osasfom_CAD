import Foundation
import osasfom_cadCore

/// Records the tangential fields on a closed box around the antenna and turns
/// them into a far-field pattern.
///
/// The equivalence principle says the fields outside a closed surface are
/// fully determined by the tangential E and H on it, so the radiation
/// integral only needs this shell — not the whole volume. Recording happens
/// as a running DFT while the run steps, because keeping a time series for
/// every surface cell would cost cells x timesteps and is out of the
/// question; that is also why the frequencies have to be chosen before the
/// run rather than swept afterwards the way S11 is.
public final class NearFieldToFarFieldExtension: EngineExtension {
    public let priority = 50
    public let extensionName: String

    /// One cell of the Huygens surface.
    struct Cell {
        /// Centre, metres, relative to the surface's own origin.
        let position: Vec3
        /// Outward normal axis (0/1/2) and its sign.
        let normalAxis: Int
        let normalSign: Double
        let area: Double
        let gridPos: (Int, Int, Int)
    }

    /// Accumulated Fourier coefficients, one array per frequency, indexed by
    /// cell. Tangential components are stored in the face's own (t1, t2)
    /// frame, which keeps the cross products below trivial.
    fileprivate struct Accumulator {
        var eT1Re: [Double], eT1Im: [Double]
        var eT2Re: [Double], eT2Im: [Double]
        var hT1Re: [Double], hT1Im: [Double]
        var hT2Re: [Double], hT2Im: [Double]

        init(cellCount: Int) {
            let zeros = [Double](repeating: 0, count: cellCount)
            eT1Re = zeros; eT1Im = zeros
            eT2Re = zeros; eT2Im = zeros
            hT1Re = zeros; hT1Im = zeros
            hT2Re = zeros; hT2Im = zeros
        }
    }

    /// Strong, like the port extension's: the handle is created as a local
    /// in the run and would otherwise be free to disappear.
    private let handle: EngineHandle
    private unowned let op: Operator
    let cells: [Cell]
    public let frequenciesHertz: [Double]
    fileprivate var accumulators: [Accumulator]
    private var stepIndex = 0

    /// Read from the operator rather than captured at init: the extension is
    /// built before `calcECOperator()`, which is where the timestep is
    /// actually derived. Capturing it at init snapshots a zero, which then
    /// multiplies every DFT sample by nothing — a far-field pattern that is
    /// silently, uniformly zero.
    private var timeStepSeconds: Double { op.dT }

    init(
        name: String,
        handle: EngineHandle,
        op: Operator,
        cells: [Cell],
        frequenciesHertz: [Double]
    ) {
        self.extensionName = name
        self.handle = handle
        self.op = op
        self.cells = cells
        self.frequenciesHertz = frequenciesHertz
        self.accumulators = frequenciesHertz.map { _ in Accumulator(cellCount: cells.count) }
    }

    // MARK: - Recording

    public func doPreVoltageUpdates() {}
    public func doPostVoltageUpdates() {}
    public func apply2Voltages() {}
    public func doPreCurrentUpdates() {}
    public func apply2Current() {}

    /// Sampled once per timestep, after both half-updates, so E and H are as
    /// close to co-timed as a leap-frog scheme allows.
    public func doPostCurrentUpdates() {
        guard let engine = handle.engine, !cells.isEmpty else { return }
        let time = Double(stepIndex) * timeStepSeconds
        stepIndex += 1

        for (frequencyIndex, frequency) in frequenciesHertz.enumerated() {
            let phase = -2 * Double.pi * frequency * time
            let cosine = cos(phase) * timeStepSeconds
            let sine = sin(phase) * timeStepSeconds

            // H trails E by half a timestep in a leap-frog update. The
            // resulting phase error is tiny at a typical FDTD step (well
            // under a degree), but it costs one rotation to remove rather
            // than leaving a known bias in the E/H balance.
            let halfStep = -Double.pi * frequency * timeStepSeconds
            let hCos = cos(phase + halfStep) * timeStepSeconds
            let hSin = sin(phase + halfStep) * timeStepSeconds

            accumulators[frequencyIndex].accumulate(
                cells: cells, engine: engine, op: op,
                eCos: cosine, eSin: sine, hCos: hCos, hSin: hSin
            )
        }
    }

    // MARK: - Transform

    /// Evaluates the radiation integral over the recorded surface.
    ///
    /// `N` and `L` are the standard radiation vectors: the Fourier transforms
    /// of the equivalent electric and magnetic surface currents,
    /// J = n̂ x H and M = -n̂ x E, projected onto each observation direction.
    func pattern(
        frequencyIndex: Int,
        thetaDegrees: [Double],
        phiDegrees: [Double],
        acceptedPowerWatts: Double?,
        reflectionCoefficient: Double?
    ) -> FarFieldPattern {
        let frequency = frequenciesHertz[frequencyIndex]
        let accumulator = accumulators[frequencyIndex]
        let waveNumber = 2 * Double.pi * frequency / FDTDConstants.C0
        let impedance = (FDTDConstants.MUE0 / FDTDConstants.EPS0).squareRoot()
        let toRadians = Double.pi / 180

        // Cartesian J and M per cell, formed once and reused for every
        // direction — the direction loop is the expensive part.
        let currents = surfaceCurrents(accumulator)

        var grid = [[Double]](
            repeating: [Double](repeating: 0, count: phiDegrees.count),
            count: thetaDegrees.count
        )

        for (thetaIndex, thetaDeg) in thetaDegrees.enumerated() {
            let theta = thetaDeg * toRadians
            let sinTheta = sin(theta), cosTheta = cos(theta)

            for (phiIndex, phiDeg) in phiDegrees.enumerated() {
                let phi = phiDeg * toRadians
                let sinPhi = sin(phi), cosPhi = cos(phi)
                let direction = Vec3(x: sinTheta * cosPhi, y: sinTheta * sinPhi, z: cosTheta)

                var nRe = Vec3.zero, nIm = Vec3.zero
                var lRe = Vec3.zero, lIm = Vec3.zero

                for (index, cell) in cells.enumerated() {
                    // e^{+jk r'·r̂}: the retardation across the surface, which
                    // is what turns a set of currents into a pattern.
                    let argument = waveNumber * cell.position.dot(direction)
                    let c = cos(argument), s = sin(argument)
                    let weight = cell.area

                    let j = currents.electric[index]
                    let m = currents.magnetic[index]

                    // (a + jb)(c + js) = (ac - bs) + j(as + bc)
                    nRe = nRe + (j.real * c - j.imaginary * s) * weight
                    nIm = nIm + (j.real * s + j.imaginary * c) * weight
                    lRe = lRe + (m.real * c - m.imaginary * s) * weight
                    lIm = lIm + (m.real * s + m.imaginary * c) * weight
                }

                // Spherical projections of the radiation vectors.
                func thetaComponent(_ v: Vec3) -> Double {
                    v.x * cosTheta * cosPhi + v.y * cosTheta * sinPhi - v.z * sinTheta
                }
                func phiComponent(_ v: Vec3) -> Double {
                    -v.x * sinPhi + v.y * cosPhi
                }

                // E_θ ∝ (L_φ + η N_θ),  E_φ ∝ (L_θ − η N_φ)
                let eThetaRe = phiComponent(lRe) + impedance * thetaComponent(nRe)
                let eThetaIm = phiComponent(lIm) + impedance * thetaComponent(nIm)
                let ePhiRe = thetaComponent(lRe) - impedance * phiComponent(nRe)
                let ePhiIm = thetaComponent(lIm) - impedance * phiComponent(nIm)

                let magnitudeSquared =
                    eThetaRe * eThetaRe + eThetaIm * eThetaIm +
                    ePhiRe * ePhiRe + ePhiIm * ePhiIm

                // U = k²/(32π²η) · |…|²
                grid[thetaIndex][phiIndex] =
                    waveNumber * waveNumber * magnitudeSquared
                    / (32 * Double.pi * Double.pi * impedance)
            }
        }

        return FarFieldPattern(
            hertz: frequency,
            thetaDegrees: thetaDegrees,
            phiDegrees: phiDegrees,
            radiationIntensity: grid,
            acceptedPowerWatts: acceptedPowerWatts,
            reflectionCoefficient: reflectionCoefficient
        )
    }

    /// J = n̂ x H and M = -n̂ x E, in Cartesian components.
    ///
    /// With (n, t1, t2) a right-handed cyclic triple, ê_n x ê_t1 = ê_t2 and
    /// ê_n x ê_t2 = -ê_t1, so the cross products collapse to a swap and a
    /// sign — no general cross product needed.
    private func surfaceCurrents(_ a: Accumulator) -> (electric: [ComplexVec3], magnetic: [ComplexVec3]) {
        var electric: [ComplexVec3] = []
        var magnetic: [ComplexVec3] = []
        electric.reserveCapacity(cells.count)
        magnetic.reserveCapacity(cells.count)

        for (index, cell) in cells.enumerated() {
            let t1 = (cell.normalAxis + 1) % 3
            let t2 = (cell.normalAxis + 2) % 3
            let sign = cell.normalSign

            var jRe = Vec3.zero, jIm = Vec3.zero
            var mRe = Vec3.zero, mIm = Vec3.zero

            // J = n̂ × H = H_t1 ê_t2 − H_t2 ê_t1
            jRe[axis(t2)] = sign * a.hT1Re[index]
            jRe[axis(t1)] = -sign * a.hT2Re[index]
            jIm[axis(t2)] = sign * a.hT1Im[index]
            jIm[axis(t1)] = -sign * a.hT2Im[index]

            // M = −n̂ × E = E_t2 ê_t1 − E_t1 ê_t2
            mRe[axis(t1)] = sign * a.eT2Re[index]
            mRe[axis(t2)] = -sign * a.eT1Re[index]
            mIm[axis(t1)] = sign * a.eT2Im[index]
            mIm[axis(t2)] = -sign * a.eT1Im[index]

            electric.append(ComplexVec3(real: jRe, imaginary: jIm))
            magnetic.append(ComplexVec3(real: mRe, imaginary: mIm))
        }
        return (electric, magnetic)
    }

    private func axis(_ index: Int) -> Axis {
        switch index {
        case 0: return .x
        case 1: return .y
        default: return .z
        }
    }
}

/// A complex-valued vector, stored as separate real and imaginary vectors so
/// the arithmetic stays plain `Vec3` operations.
struct ComplexVec3 {
    var real: Vec3
    var imaginary: Vec3
}

private extension NearFieldToFarFieldExtension.Accumulator {
    /// One timestep's contribution to the running DFT of every surface cell.
    mutating func accumulate(
        cells: [NearFieldToFarFieldExtension.Cell],
        engine: Engine,
        op: Operator,
        eCos: Double, eSin: Double,
        hCos: Double, hSin: Double
    ) {
        for (index, cell) in cells.enumerated() {
            let t1 = (cell.normalAxis + 1) % 3
            let t2 = (cell.normalAxis + 2) % 3
            let pos = cell.gridPos

            // volt is E integrated along an edge, curr is H along the dual
            // edge — divide by the respective lengths to recover field
            // strengths the radiation integral can use.
            let e1Length = op.getEdgeLength(t1, pos)
            let e2Length = op.getEdgeLength(t2, pos)
            let h1Length = op.getEdgeLength(t1, pos, dualMesh: true)
            let h2Length = op.getEdgeLength(t2, pos, dualMesh: true)

            let e1 = e1Length > 0 ? engine.getVolt(t1, pos.0, pos.1, pos.2) / e1Length : 0
            let e2 = e2Length > 0 ? engine.getVolt(t2, pos.0, pos.1, pos.2) / e2Length : 0
            let h1 = h1Length > 0 ? engine.getCurr(t1, pos.0, pos.1, pos.2) / h1Length : 0
            let h2 = h2Length > 0 ? engine.getCurr(t2, pos.0, pos.1, pos.2) / h2Length : 0

            eT1Re[index] += e1 * eCos; eT1Im[index] += e1 * eSin
            eT2Re[index] += e2 * eCos; eT2Im[index] += e2 * eSin
            hT1Re[index] += h1 * hCos; hT1Im[index] += h1 * hSin
            hT2Re[index] += h2 * hCos; hT2Im[index] += h2 * hSin
        }
    }
}


// MARK: - Surface construction

extension NearFieldToFarFieldExtension {

    /// Builds a closed box of surface cells inside the absorbing boundary.
    ///
    /// The surface has to sit in the region the solver still models
    /// faithfully: outside the antenna's reactive near field, but well inside
    /// the PML, whose whole job is to attenuate the fields the transform
    /// needs to read. `insetCells` past the absorber is the margin for that.
    /// Returns `nil` when the grid is too small to hold a box with any
    /// interior, which is the honest outcome for a domain that never had room
    /// for a far-field surface.
    static func makeSurface(
        op: Operator,
        pmlCellCount: Int,
        insetCells: Int = 2,
        minimumInteriorCells: Int = 4
    ) -> [Cell]? {
        let counts = (op.numLines.0, op.numLines.1, op.numLines.2)
        let margin = max(pmlCellCount + insetCells, 1)

        let lower = (margin, margin, margin)
        let upper = (counts.0 - 1 - margin, counts.1 - 1 - margin, counts.2 - 1 - margin)

        // No room means no surface, and saying so is the only honest answer.
        // An earlier version quietly shrank the margin instead, which put the
        // surface *inside* the PML — whose entire job is to absorb the fields
        // the transform needs to read. The result was a pattern of all zeros
        // that looked like a working feature.
        guard
            upper.0 - lower.0 >= minimumInteriorCells,
            upper.1 - lower.1 >= minimumInteriorCells,
            upper.2 - lower.2 >= minimumInteriorCells
        else { return nil }

        // Centre the phase reference on the box, so the retardation term is
        // symmetric and stays numerically small.
        let centre = Vec3(
            x: (op.getDiscLine(0, lower.0) + op.getDiscLine(0, upper.0)) / 2 * op.gridDelta,
            y: (op.getDiscLine(1, lower.1) + op.getDiscLine(1, upper.1)) / 2 * op.gridDelta,
            z: (op.getDiscLine(2, lower.2) + op.getDiscLine(2, upper.2)) / 2 * op.gridDelta
        )

        func bound(_ axis: Int) -> (low: Int, high: Int) {
            switch axis {
            case 0: return (lower.0, upper.0)
            case 1: return (lower.1, upper.1)
            default: return (lower.2, upper.2)
            }
        }

        var cells: [Cell] = []
        for normalAxis in 0..<3 {
            let t1 = (normalAxis + 1) % 3
            let t2 = (normalAxis + 2) % 3
            let t1Bounds = bound(t1)
            let t2Bounds = bound(t2)
            let normalBounds = bound(normalAxis)

            for (plane, sign) in [(normalBounds.low, -1.0), (normalBounds.high, 1.0)] {
                for i in t1Bounds.low..<t1Bounds.high {
                    for j in t2Bounds.low..<t2Bounds.high {
                        var pos = (0, 0, 0)
                        set(&pos, normalAxis, plane)
                        set(&pos, t1, i)
                        set(&pos, t2, j)

                        let width1 = op.getEdgeLength(t1, pos)
                        let width2 = op.getEdgeLength(t2, pos)
                        guard width1 > 0, width2 > 0 else { continue }

                        var position = Vec3.zero
                        position[axisOf(normalAxis)] = op.getDiscLine(normalAxis, plane) * op.gridDelta
                        position[axisOf(t1)] = op.getDiscLine(t1, i, dualMesh: true) * op.gridDelta
                        position[axisOf(t2)] = op.getDiscLine(t2, j, dualMesh: true) * op.gridDelta

                        cells.append(
                            Cell(
                                position: position - centre,
                                normalAxis: normalAxis,
                                normalSign: sign,
                                area: width1 * width2,
                                gridPos: pos
                            )
                        )
                    }
                }
            }
        }
        return cells.isEmpty ? nil : cells
    }

    private static func set(_ pos: inout (Int, Int, Int), _ axis: Int, _ value: Int) {
        switch axis {
        case 0: pos.0 = value
        case 1: pos.1 = value
        default: pos.2 = value
        }
    }

    private static func axisOf(_ index: Int) -> Axis {
        switch index {
        case 0: return .x
        case 1: return .y
        default: return .z
        }
    }

    /// The θ/φ sampling grid a pattern is evaluated on. θ spans both poles
    /// inclusively; φ stops one step short of 360°, which is the same
    /// direction as 0°.
    static func angleGrid(stepDegrees: Double) -> (theta: [Double], phi: [Double]) {
        let step = min(max(stepDegrees, 1), 30)
        let thetaCount = max(Int((180.0 / step).rounded()), 2)
        let phiCount = max(Int((360.0 / step).rounded()), 4)
        let theta = (0...thetaCount).map { 180.0 * Double($0) / Double(thetaCount) }
        let phi = (0..<phiCount).map { 360.0 * Double($0) / Double(phiCount) }
        return (theta, phi)
    }
}
