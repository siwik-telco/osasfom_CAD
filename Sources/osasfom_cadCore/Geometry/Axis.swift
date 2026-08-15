import Foundation

/// A cartesian axis. Used for cylinder orientation, sheet normals, port
/// direction, and per-axis mesh and boundary settings.
public enum Axis: String, Codable, CaseIterable, Identifiable, Sendable {
    case x
    case y
    case z

    public var id: String { rawValue }

    public var displayName: String { rawValue.uppercased() }

    public var unitVector: Vec3 {
        switch self {
        case .x: return Vec3(x: 1, y: 0, z: 0)
        case .y: return Vec3(x: 0, y: 1, z: 0)
        case .z: return Vec3(x: 0, y: 0, z: 1)
        }
    }

    /// The two axes perpendicular to this one, in right-handed cyclic order.
    public var perpendicular: (Axis, Axis) {
        switch self {
        case .x: return (.y, .z)
        case .y: return (.z, .x)
        case .z: return (.x, .y)
        }
    }

    /// Euler angles (degrees) that rotate the +Y axis onto this axis. SceneKit's
    /// `SCNCylinder` is Y-aligned, so this is what orients a cylinder mesh.
    public var rotationFromYAxisDegrees: Vec3 {
        switch self {
        case .x: return Vec3(x: 0, y: 0, z: -90)
        case .y: return .zero
        case .z: return Vec3(x: 90, y: 0, z: 0)
        }
    }
}
