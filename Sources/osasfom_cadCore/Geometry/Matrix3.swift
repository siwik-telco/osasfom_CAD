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

    /// The inverse rotation. A rotation matrix is orthonormal, so its
    /// inverse is just its transpose — no general 3x3 inversion needed.
    public var transposed: Matrix3 {
        Matrix3(
            column0: Vec3(x: columns.0.x, y: columns.1.x, z: columns.2.x),
            column1: Vec3(x: columns.0.y, y: columns.1.y, z: columns.2.y),
            column2: Vec3(x: columns.0.z, y: columns.1.z, z: columns.2.z)
        )
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

    /// The inverse of `euler(degrees:)` — the angles that rebuild this matrix.
    ///
    /// Needed because composing rotations is matrix work, but a body stores
    /// Euler angles: transforming an already-rotated body means going to a
    /// matrix, multiplying, and coming back.
    ///
    /// Angles are not unique (every orientation has at least two Euler
    /// triples), so this returns *a* triple that reproduces the matrix, not
    /// the one someone originally typed. Round-tripping is exact in the
    /// matrix, not in the numbers.
    public var eulerDegrees: Vec3 {
        // Element (row, column); `columns` is column-major, so m[r][c] is
        // columns.c[r]. With M = Rx·Ry·Rz:
        //   m02 =  sin(b)
        //   m12 = -sin(a)·cos(b),  m22 = cos(a)·cos(b)
        //   m00 =  cos(b)·cos(c),  m01 = -cos(b)·sin(c)
        let m02 = columns.2.x
        let m12 = columns.2.y
        let m22 = columns.2.z
        let m00 = columns.0.x
        let m01 = columns.1.x
        let m10 = columns.0.y
        let m11 = columns.1.y

        let toDegrees = 180 / Double.pi
        let sinB = Swift.min(Swift.max(m02, -1), 1)
        let b = asin(sinB)

        // Gimbal lock: at b = ±90° the X and Z rotations act on the same axis
        // and only their sum (or difference) is recoverable. Pinning A to zero
        // and putting everything in C is the conventional resolution.
        guard abs(m02) < 1 - 1e-9 else {
            return Vec3(x: 0, y: b * toDegrees, z: atan2(m10, m11) * toDegrees)
        }

        return Vec3(
            x: atan2(-m12, m22) * toDegrees,
            y: b * toDegrees,
            z: atan2(-m01, m00) * toDegrees
        )
    }

    /// Reflection through the plane normal to `axis`. Not a rotation — its
    /// determinant is −1 — but `M·R·M` is, which is how a mirrored body's
    /// orientation is recovered.
    public static func reflection(normalTo axis: Axis) -> Matrix3 {
        var matrix = Matrix3.identity
        switch axis {
        case .x: matrix.columns.0 = Vec3(x: -1, y: 0, z: 0)
        case .y: matrix.columns.1 = Vec3(x: 0, y: -1, z: 0)
        case .z: matrix.columns.2 = Vec3(x: 0, y: 0, z: -1)
        }
        return matrix
    }
}
