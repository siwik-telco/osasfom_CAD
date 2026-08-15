import Foundation

/// A point or extent in model space. Values are expressed in the project's
/// `LengthUnit`; conversion to SI happens only at the solver-export boundary.
public struct Vec3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(repeating value: Double) {
        self.init(x: value, y: value, z: value)
    }

    public static let zero = Vec3(repeating: 0)
    public static let one = Vec3(repeating: 1)

    public subscript(axis: Axis) -> Double {
        get {
            switch axis {
            case .x: return x
            case .y: return y
            case .z: return z
            }
        }
        set {
            switch axis {
            case .x: x = newValue
            case .y: y = newValue
            case .z: z = newValue
            }
        }
    }

    public var components: [Double] { [x, y, z] }

    public var largestComponent: Double { max(max(abs(x), abs(y)), abs(z)) }

    public static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    public static func * (lhs: Vec3, rhs: Double) -> Vec3 {
        Vec3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    public static func / (lhs: Vec3, rhs: Double) -> Vec3 {
        Vec3(x: lhs.x / rhs, y: lhs.y / rhs, z: lhs.z / rhs)
    }

    /// Component-wise product, used for applying a non-uniform scale.
    public func scaled(by factors: Vec3) -> Vec3 {
        Vec3(x: x * factors.x, y: y * factors.y, z: z * factors.z)
    }

    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
