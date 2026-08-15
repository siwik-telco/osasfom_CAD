import Foundation

/// A 3x3 rotation matrix.
///
/// The Euler convention matches `SCNNode.eulerAngles`: components are pitch (X),
/// yaw (Y) and roll (Z), and rotations are applied in reverse order — roll
/// first, then yaw, then pitch. That makes the combined matrix `Rx * Ry * Rz`.
/// Core and the renderer must agree on this or bounding boxes drift away from
/// what is drawn.
public struct Matrix3: Hashable, Sendable {
    public var columns: (Vec3, Vec3, Vec3)

    public init(column0: Vec3, column1: Vec3, column2: Vec3) {
        self.columns = (column0, column1, column2)
    }

    public static let identity = Matrix3(
        column0: Vec3(x: 1, y: 0, z: 0),
        column1: Vec3(x: 0, y: 1, z: 0),
        column2: Vec3(x: 0, y: 0, z: 1)
    )

    public static func == (lhs: Matrix3, rhs: Matrix3) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1 && lhs.columns.2 == rhs.columns.2
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(columns.0)
        hasher.combine(columns.1)
        hasher.combine(columns.2)
    }

    public func apply(to vector: Vec3) -> Vec3 {
        columns.0 * vector.x + columns.1 * vector.y + columns.2 * vector.z
    }

    public static func * (lhs: Matrix3, rhs: Matrix3) -> Matrix3 {
        Matrix3(
            column0: lhs.apply(to: rhs.columns.0),
            column1: lhs.apply(to: rhs.columns.1),
            column2: lhs.apply(to: rhs.columns.2)
        )
    }

    public static func rotationX(radians: Double) -> Matrix3 {
        let cosine = cos(radians)
        let sine = sin(radians)
        return Matrix3(
            column0: Vec3(x: 1, y: 0, z: 0),
            column1: Vec3(x: 0, y: cosine, z: sine),
            column2: Vec3(x: 0, y: -sine, z: cosine)
        )
    }

    public static func rotationY(radians: Double) -> Matrix3 {
        let cosine = cos(radians)
        let sine = sin(radians)
        return Matrix3(
            column0: Vec3(x: cosine, y: 0, z: -sine),
            column1: Vec3(x: 0, y: 1, z: 0),
            column2: Vec3(x: sine, y: 0, z: cosine)
        )
    }

    public static func rotationZ(radians: Double) -> Matrix3 {
        let cosine = cos(radians)
        let sine = sin(radians)
        return Matrix3(
            column0: Vec3(x: cosine, y: sine, z: 0),
            column1: Vec3(x: -sine, y: cosine, z: 0),
            column2: Vec3(x: 0, y: 0, z: 1)
        )
    }

    /// `Rx * Ry * Rz`, matching `SCNNode.eulerAngles`.
    public static func euler(degrees angles: Vec3) -> Matrix3 {
        let toRadians = Double.pi / 180
        return rotationX(radians: angles.x * toRadians)
            * rotationY(radians: angles.y * toRadians)
            * rotationZ(radians: angles.z * toRadians)
    }
}
