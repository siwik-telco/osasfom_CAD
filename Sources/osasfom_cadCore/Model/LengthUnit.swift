import Foundation

/// The project's length unit.
///
/// All model numbers are in this unit; the solver export converts to metres at
/// the boundary. Replaces the old free-form `units: String`, which nothing read.
public enum LengthUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case micrometer
    case millimeter
    case centimeter
    case meter
    case mil
    case inch

    public var id: String { rawValue }

    public var metersPerUnit: Double {
        switch self {
        case .micrometer: return 1e-6
        case .millimeter: return 1e-3
        case .centimeter: return 1e-2
        case .meter: return 1
        case .mil: return 2.54e-5
        case .inch: return 2.54e-2
        }
    }

    public var symbol: String {
        switch self {
        case .micrometer: return "µm"
        case .millimeter: return "mm"
        case .centimeter: return "cm"
        case .meter: return "m"
        case .mil: return "mil"
        case .inch: return "in"
        }
    }

    public var displayName: String {
        switch self {
        case .micrometer: return "Micrometers (µm)"
        case .millimeter: return "Millimeters (mm)"
        case .centimeter: return "Centimeters (cm)"
        case .meter: return "Meters (m)"
        case .mil: return "Mils (mil)"
        case .inch: return "Inches (in)"
        }
    }

    public func toMeters(_ value: Double) -> Double { value * metersPerUnit }

    public func fromMeters(_ meters: Double) -> Double { meters / metersPerUnit }

    public func toMeters(_ vector: Vec3) -> Vec3 { vector * metersPerUnit }

    public func toMeters(_ bounds: BodyBounds) -> BodyBounds {
        BodyBounds(
            xMin: toMeters(bounds.xMin),
            xMax: toMeters(bounds.xMax),
            yMin: toMeters(bounds.yMin),
            yMax: toMeters(bounds.yMax),
            zMin: toMeters(bounds.zMin),
            zMax: toMeters(bounds.zMax)
        )
    }

    /// Free-space wavelength at `hertz`, expressed in this unit. Handy for mesh
    /// sanity checks.
    public func wavelength(atHertz hertz: Double) -> Double? {
        guard hertz > 0 else { return nil }
        return fromMeters(299_792_458.0 / hertz)
    }
}

/// Frequency formatting helper, shared by the inspector and the export summary.
public enum FrequencyFormatter {
    public static func string(hertz: Double) -> String {
        let magnitude = abs(hertz)
        let (scale, suffix): (Double, String)
        switch magnitude {
        case 1e9...: (scale, suffix) = (1e9, "GHz")
        case 1e6..<1e9: (scale, suffix) = (1e6, "MHz")
        case 1e3..<1e6: (scale, suffix) = (1e3, "kHz")
        default: (scale, suffix) = (1, "Hz")
        }
        return "\(Expression.literalSource(hertz / scale)) \(suffix)"
    }
}
