import Foundation
import osasfom_cadCore

/// Which quantity a pattern plot shows.
///
/// Kept explicit because the three differ by real, physically meaningful
/// factors, and antenna results are routinely misquoted by conflating them:
/// directivity ignores loss entirely, gain folds in the antenna's own losses,
/// and realized gain additionally folds in the mismatch at the port.
public enum FarFieldQuantity: String, CaseIterable, Identifiable, Sendable {
    case directivity
    case realizedGain
    case normalized

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .directivity: return "Directivity"
        case .realizedGain: return "Realized gain"
        case .normalized: return "Normalized"
        }
    }

    public var unitLabel: String {
        switch self {
        case .directivity, .realizedGain: return "dBi"
        case .normalized: return "dB"
        }
    }
}

/// One direction's worth of far field.
public struct FarFieldSample: Hashable, Sendable {
    public let thetaDegrees: Double
    public let phiDegrees: Double
    /// Radiation intensity, W/sr.
    public let radiationIntensity: Double

    public init(thetaDegrees: Double, phiDegrees: Double, radiationIntensity: Double) {
        self.thetaDegrees = thetaDegrees
        self.phiDegrees = phiDegrees
        self.radiationIntensity = radiationIntensity
    }
}

/// A complete radiation pattern at one frequency.
///
/// Stores radiation intensity U(θ, φ) in W/sr rather than a normalized shape,
/// so directivity, gain and realized gain can all be derived from the same
/// grid without re-running anything.
public struct FarFieldPattern: Codable, Sendable {
    public let hertz: Double
    /// Ascending, 0…180 inclusive.
    public let thetaDegrees: [Double]
    /// Ascending, 0…360 exclusive — 360° is the same direction as 0°.
    public let phiDegrees: [Double]
    /// `[thetaIndex][phiIndex]`, W/sr.
    public let radiationIntensity: [[Double]]
    /// Integrated over the sphere, W.
    public let radiatedPowerWatts: Double
    /// Power the port actually delivered into the structure, W. `nil` when
    /// the run had no usable port data, which is what makes gain unavailable
    /// while directivity still works.
    public let acceptedPowerWatts: Double?
    /// |S11| at this frequency, linear. Drives the mismatch term of realized
    /// gain.
    public let reflectionCoefficient: Double?

    public init(
        hertz: Double,
        thetaDegrees: [Double],
        phiDegrees: [Double],
        radiationIntensity: [[Double]],
        acceptedPowerWatts: Double? = nil,
        reflectionCoefficient: Double? = nil
    ) {
        self.hertz = hertz
        self.thetaDegrees = thetaDegrees
        self.phiDegrees = phiDegrees
        self.radiationIntensity = radiationIntensity
        self.acceptedPowerWatts = acceptedPowerWatts
        self.reflectionCoefficient = reflectionCoefficient
        self.radiatedPowerWatts = Self.integrate(
            radiationIntensity,
            thetaDegrees: thetaDegrees,
            phiDegrees: phiDegrees
        )
    }

    // MARK: - Codable
    //
    // Only the recorded inputs are stored; `radiatedPowerWatts` is re-derived
    // through the normal initializer, so a decoded pattern can never disagree
    // with one that was just computed.

    private enum CodingKeys: String, CodingKey {
        case hertz, thetaDegrees, phiDegrees, radiationIntensity
        case acceptedPowerWatts, reflectionCoefficient
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hertz: try container.decode(Double.self, forKey: .hertz),
            thetaDegrees: try container.decode([Double].self, forKey: .thetaDegrees),
            phiDegrees: try container.decode([Double].self, forKey: .phiDegrees),
            radiationIntensity: try container.decode([[Double]].self, forKey: .radiationIntensity),
            acceptedPowerWatts: try container.decodeIfPresent(Double.self, forKey: .acceptedPowerWatts),
            reflectionCoefficient: try container.decodeIfPresent(Double.self, forKey: .reflectionCoefficient)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hertz, forKey: .hertz)
        try container.encode(thetaDegrees, forKey: .thetaDegrees)
        try container.encode(phiDegrees, forKey: .phiDegrees)
        try container.encode(radiationIntensity, forKey: .radiationIntensity)
        try container.encodeIfPresent(acceptedPowerWatts, forKey: .acceptedPowerWatts)
        try container.encodeIfPresent(reflectionCoefficient, forKey: .reflectionCoefficient)
    }

    // MARK: - Integration

    /// ∮ U dΩ  =  ∫∫ U(θ,φ) sinθ dθ dφ.
    ///
    /// The sinθ factor is integrated *analytically* over each θ band —
    /// ∫sinθ dθ = cos θ_lo − cos θ_hi — rather than sampled at the band
    /// centre. Sampling it leaves a second-order error that showed up as a
    /// 1e-4 discrepancy in the total radiated power, which then biases every
    /// directivity figure derived from it. Doing it this way makes the
    /// solid angles sum to exactly 4π regardless of step size, so an
    /// isotropic pattern reports exactly 0 dBi.
    ///
    /// Only U itself is treated as piecewise constant across a cell, which is
    /// the honest approximation: it is the part actually sampled.
    private static func integrate(
        _ intensity: [[Double]],
        thetaDegrees: [Double],
        phiDegrees: [Double]
    ) -> Double {
        guard !thetaDegrees.isEmpty, !phiDegrees.isEmpty else { return 0 }
        let deltaPhi = 2 * Double.pi / Double(phiDegrees.count)

        var total = 0.0
        for (i, _) in thetaDegrees.enumerated() {
            let row = intensity[i]
            guard !row.isEmpty else { continue }
            total += row.reduce(0, +) * bandSolidAngleFactor(i, thetaDegrees) * deltaPhi
        }
        return total
    }

    /// ∫ sinθ dθ across the θ band that sample `i` represents, whose edges
    /// are the midpoints to its neighbours (clamped to the poles).
    private static func bandSolidAngleFactor(_ i: Int, _ thetaDegrees: [Double]) -> Double {
        let toRadians = Double.pi / 180
        let theta = thetaDegrees[i] * toRadians
        let lower = i > 0 ? (thetaDegrees[i - 1] * toRadians + theta) / 2 : 0
        let upper = i < thetaDegrees.count - 1 ? (theta + thetaDegrees[i + 1] * toRadians) / 2 : .pi
        return cos(max(lower, 0)) - cos(min(upper, .pi))
    }

    // MARK: - Derived figures

    /// Fraction of accepted power that leaves as radiation. Below 1 when the
    /// model has lossy material (an FR-4 substrate, finite-conductivity
    /// copper) — this is what separates gain from directivity.
    public var radiationEfficiency: Double? {
        guard let accepted = acceptedPowerWatts, accepted > 0 else { return nil }
        return min(radiatedPowerWatts / accepted, 1)
    }

    /// Fraction of incident power not reflected at the port, 1 − |Γ|².
    public var mismatchEfficiency: Double? {
        guard let gamma = reflectionCoefficient else { return nil }
        return max(0, 1 - gamma * gamma)
    }

    /// D(θ, φ) = 4π U / P_rad, linear.
    public func directivity(thetaIndex: Int, phiIndex: Int) -> Double {
        guard radiatedPowerWatts > 0 else { return 0 }
        return 4 * .pi * radiationIntensity[thetaIndex][phiIndex] / radiatedPowerWatts
    }

    public var peakRadiationIntensity: Double {
        radiationIntensity.flatMap { $0 }.max() ?? 0
    }

    public var peakDirectivity: Double {
        guard radiatedPowerWatts > 0 else { return 0 }
        return 4 * .pi * peakRadiationIntensity / radiatedPowerWatts
    }

    public var peakDirectivityDbi: Double { Self.decibels(peakDirectivity) }

    /// The direction the peak points, for reporting boresight.
    public var peakDirection: (thetaDegrees: Double, phiDegrees: Double)? {
        var best = -Double.greatestFiniteMagnitude
        var found: (Double, Double)?
        for (i, row) in radiationIntensity.enumerated() {
            for (j, value) in row.enumerated() where value > best {
                best = value
                found = (thetaDegrees[i], phiDegrees[j])
            }
        }
        return found
    }

    /// G = η_rad · D. `nil` without port data.
    public var peakGainDbi: Double? {
        guard let efficiency = radiationEfficiency else { return nil }
        return Self.decibels(peakDirectivity * efficiency)
    }

    /// G_realized = (1 − |Γ|²) · η_rad · D — what the antenna delivers when
    /// driven from a matched source, mismatch included.
    public var peakRealizedGainDbi: Double? {
        guard let efficiency = radiationEfficiency, let mismatch = mismatchEfficiency else { return nil }
        return Self.decibels(peakDirectivity * efficiency * mismatch)
    }

    /// The constant offset from directivity to the requested quantity, in dB.
    /// `nil` when the quantity can't be formed from what this run captured.
    public func offsetDb(for quantity: FarFieldQuantity) -> Double? {
        switch quantity {
        case .directivity:
            return 0
        case .normalized:
            return -peakDirectivityDbi
        case .realizedGain:
            guard let efficiency = radiationEfficiency, let mismatch = mismatchEfficiency else { return nil }
            return Self.decibels(efficiency * mismatch)
        }
    }

    /// Whether `quantity` can be shown at all for this pattern.
    public func supports(_ quantity: FarFieldQuantity) -> Bool {
        offsetDb(for: quantity) != nil
    }

    public func valueDb(thetaIndex: Int, phiIndex: Int, quantity: FarFieldQuantity) -> Double {
        let base = Self.decibels(directivity(thetaIndex: thetaIndex, phiIndex: phiIndex))
        return base + (offsetDb(for: quantity) ?? 0)
    }

    /// A floor of −60 dB rather than −∞: a true null would otherwise drag a
    /// polar plot's axis to negative infinity and erase the pattern.
    static func decibels(_ linear: Double) -> Double {
        guard linear > 1e-12 else { return -60 }
        return max(10 * log10(linear), -60)
    }
}

// MARK: - 1D cuts

/// One point of a pattern cut: an angle around the plot and a value in dB.
public struct PatternCutPoint: Hashable, Sendable {
    /// Position around the polar plot, degrees.
    public let angleDegrees: Double
    public let decibels: Double

    public init(angleDegrees: Double, decibels: Double) {
        self.angleDegrees = angleDegrees
        self.decibels = decibels
    }
}

/// A single-plane slice through the pattern.
public struct PatternCut: Identifiable, Sendable {
    public enum Plane: Hashable, Sendable {
        /// A constant-φ plane, swept in θ from −180° to +180°. The negative
        /// half is the φ+180° side of the same plane, which is what makes the
        /// polar trace a full circle rather than a half-disc.
        case constantPhi(Double)
        /// A constant-θ cone, swept in φ from 0° to 360°.
        case constantTheta(Double)
    }

    public let plane: Plane
    public let quantity: FarFieldQuantity
    public let points: [PatternCutPoint]

    public var id: String { name }

    public var name: String {
        switch plane {
        case .constantPhi(let phi): return "φ = \(Self.angleText(phi))°"
        case .constantTheta(let theta): return "θ = \(Self.angleText(theta))°"
        }
    }

    /// What the sweep axis means, so a reader can tell the two cut kinds apart.
    public var sweepLabel: String {
        switch plane {
        case .constantPhi: return "θ"
        case .constantTheta: return "φ"
        }
    }

    /// The conventional name for this plane on a broadside patch: the φ=0
    /// plane holds the E-field direction, φ=90 the H-field.
    public var conventionalName: String? {
        switch plane {
        case .constantPhi(let phi) where phi == 0: return "E-plane"
        case .constantPhi(let phi) where phi == 90: return "H-plane"
        case .constantTheta(let theta) where theta == 90: return "horizon"
        default: return nil
        }
    }

    private static func angleText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    public var peakDecibels: Double { points.map(\.decibels).max() ?? -60 }

    /// Half-power beamwidth: the angular width where the trace stays within
    /// 3 dB of its peak, measured across the main lobe. `nil` when the trace
    /// never drops 3 dB (an omnidirectional cut has no beamwidth to quote).
    public var halfPowerBeamwidthDegrees: Double? {
        guard let peakIndex = points.indices.max(by: { points[$0].decibels < points[$1].decibels }) else {
            return nil
        }
        let threshold = points[peakIndex].decibels - 3

        func edge(step: Int) -> Double? {
            var index = peakIndex
            var previous = points[peakIndex]
            for _ in 0..<points.count {
                let next = index + step
                guard next >= 0, next < points.count else { return nil }
                let point = points[next]
                if point.decibels <= threshold {
                    // Linear interpolation onto the exact −3 dB crossing.
                    let span = previous.decibels - point.decibels
                    let fraction = span > 0 ? (previous.decibels - threshold) / span : 0
                    return previous.angleDegrees + (point.angleDegrees - previous.angleDegrees) * fraction
                }
                previous = point
                index = next
            }
            return nil
        }

        guard let lower = edge(step: -1), let upper = edge(step: 1) else { return nil }
        return abs(upper - lower)
    }

    /// Front-to-back ratio: peak minus the value 180° away from it.
    public var frontToBackDb: Double? {
        guard let peakIndex = points.indices.max(by: { points[$0].decibels < points[$1].decibels }) else {
            return nil
        }
        let peak = points[peakIndex]
        let target = peak.angleDegrees + 180
        func wrapped(_ angle: Double) -> Double {
            var value = angle.truncatingRemainder(dividingBy: 360)
            if value > 180 { value -= 360 }
            if value < -180 { value += 360 }
            return value
        }
        let wantedAngle = wrapped(target)
        guard let back = points.min(by: {
            abs(wrapped($0.angleDegrees - wantedAngle)) < abs(wrapped($1.angleDegrees - wantedAngle))
        }) else { return nil }
        return peak.decibels - back.decibels
    }
}

extension FarFieldPattern {
    /// Nearest grid index, so a cut can be asked for at any angle even when
    /// the sampling step doesn't divide it exactly.
    private static func nearestIndex(_ values: [Double], _ target: Double) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, value) in values.enumerated() {
            let distance = abs(value - target)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// A constant-φ cut, swept −180…180 in θ.
    ///
    /// The negative half comes from the φ+180° column of the same grid, so
    /// the trace runs continuously around the plot instead of doubling back
    /// on itself.
    public func cut(atPhiDegrees phi: Double, quantity: FarFieldQuantity) -> PatternCut {
        let forwardIndex = Self.nearestIndex(phiDegrees, normalizedPhi(phi))
        let backIndex = Self.nearestIndex(phiDegrees, normalizedPhi(phi + 180))

        var points: [PatternCutPoint] = []
        // −180 … 0, walking the far half inward from the south pole.
        for index in thetaDegrees.indices.reversed() {
            let theta = thetaDegrees[index]
            guard theta > 0, theta < 180 else { continue }
            points.append(
                PatternCutPoint(
                    angleDegrees: -theta,
                    decibels: valueDb(thetaIndex: index, phiIndex: backIndex, quantity: quantity)
                )
            )
        }
        // 0 … 180 on the near half, poles included.
        for index in thetaDegrees.indices {
            points.append(
                PatternCutPoint(
                    angleDegrees: thetaDegrees[index],
                    decibels: valueDb(thetaIndex: index, phiIndex: forwardIndex, quantity: quantity)
                )
            )
        }
        return PatternCut(plane: .constantPhi(normalizedPhi(phi)), quantity: quantity, points: points)
    }

    /// A constant-θ cut, swept 0…360 in φ. The 360° point repeats 0° so a
    /// polar trace closes on itself.
    public func cut(atThetaDegrees theta: Double, quantity: FarFieldQuantity) -> PatternCut {
        let thetaIndex = Self.nearestIndex(thetaDegrees, min(max(theta, 0), 180))
        var points = phiDegrees.indices.map { index in
            PatternCutPoint(
                angleDegrees: phiDegrees[index],
                decibels: valueDb(thetaIndex: thetaIndex, phiIndex: index, quantity: quantity)
            )
        }
        if let first = points.first {
            points.append(PatternCutPoint(angleDegrees: 360, decibels: first.decibels))
        }
        return PatternCut(
            plane: .constantTheta(thetaDegrees[thetaIndex]),
            quantity: quantity,
            points: points
        )
    }

    /// The three cuts the pattern view shows: the two principal planes and
    /// the horizon cone.
    public func principalCuts(quantity: FarFieldQuantity, thetaCutDegrees: Double = 90) -> [PatternCut] {
        [
            cut(atPhiDegrees: 0, quantity: quantity),
            cut(atPhiDegrees: 90, quantity: quantity),
            cut(atThetaDegrees: thetaCutDegrees, quantity: quantity)
        ]
    }

    private func normalizedPhi(_ value: Double) -> Double {
        var phi = value.truncatingRemainder(dividingBy: 360)
        if phi < 0 { phi += 360 }
        return phi
    }
}


// MARK: - Renderable surface

extension FarFieldPattern {
    /// A deformed-sphere mesh of this pattern, sized to `radius` in model
    /// units so it can be drawn against the antenna it came from.
    ///
    /// `dynamicRangeDb` sets how far below the peak the surface collapses to
    /// the origin. 40 dB shows sidelobe structure; tighten it to emphasise
    /// the main lobe.
    public func mesh(
        quantity: FarFieldQuantity = .directivity,
        radius: Double,
        dynamicRangeDb: Double = 40
    ) -> FarFieldMesh {
        let peak: Double
        switch quantity {
        case .normalized: peak = 0
        case .directivity: peak = peakDirectivityDbi
        case .realizedGain: peak = peakRealizedGainDbi ?? peakDirectivityDbi
        }

        return FarFieldMesh.make(
            thetaDegrees: thetaDegrees,
            phiDegrees: phiDegrees,
            peakDb: peak,
            dynamicRangeDb: dynamicRangeDb,
            radius: radius
        ) { thetaIndex, phiIndex in
            valueDb(thetaIndex: thetaIndex, phiIndex: phiIndex, quantity: quantity)
        }
    }
}
