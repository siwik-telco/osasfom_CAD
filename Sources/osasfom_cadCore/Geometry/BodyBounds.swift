import Foundation

/// An axis-aligned box in model space.
///
/// Used in three distinct roles, which are deliberately kept separate:
/// * the *true* axis-aligned bounding box of a resolved body (read-only, and
///   correct for rotated bodies),
/// * the local extent editor for unrotated boxes and sheets,
/// * the FDTD computational domain and lumped-port extents.
public struct BodyBounds: Codable, Hashable, Sendable {
    public var xMin: Double
    public var xMax: Double
    public var yMin: Double
    public var yMax: Double
    public var zMin: Double
    public var zMax: Double

    public init(
        xMin: Double,
        xMax: Double,
        yMin: Double,
        yMax: Double,
        zMin: Double,
        zMax: Double
    ) {
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
        self.zMin = zMin
        self.zMax = zMax
    }

    /// Builds the bounds from a centre point and full extents.
    public init(center: Vec3, size: Vec3) {
        self.init(
            xMin: center.x - size.x / 2,
            xMax: center.x + size.x / 2,
            yMin: center.y - size.y / 2,
            yMax: center.y + size.y / 2,
            zMin: center.z - size.z / 2,
            zMax: center.z + size.z / 2
        )
    }

    public var minimum: Vec3 { Vec3(x: xMin, y: yMin, z: zMin) }
    public var maximum: Vec3 { Vec3(x: xMax, y: yMax, z: zMax) }

    public var center: Vec3 {
        Vec3(x: (xMin + xMax) / 2, y: (yMin + yMax) / 2, z: (zMin + zMax) / 2)
    }

    /// Full extents. May legitimately contain a zero component — an infinitely
    /// thin PEC sheet is a valid FDTD construct.
    public var size: Vec3 {
        Vec3(x: xMax - xMin, y: yMax - yMin, z: zMax - zMin)
    }

    public var isInverted: Bool { xMax < xMin || yMax < yMin || zMax < zMin }

    public func lower(on axis: Axis) -> Double { minimum[axis] }
    public func upper(on axis: Axis) -> Double { maximum[axis] }

    public func span(on axis: Axis) -> Double { size[axis] }

    /// Swaps any inverted min/max pair. Never widens a zero-thickness span.
    public func normalized() -> BodyBounds {
        BodyBounds(
            xMin: min(xMin, xMax),
            xMax: max(xMin, xMax),
            yMin: min(yMin, yMax),
            yMax: max(yMin, yMax),
            zMin: min(zMin, zMax),
            zMax: max(zMin, zMax)
        )
    }

    public func expanded(by padding: Vec3) -> BodyBounds {
        BodyBounds(
            xMin: xMin - padding.x,
            xMax: xMax + padding.x,
            yMin: yMin - padding.y,
            yMax: yMax + padding.y,
            zMin: zMin - padding.z,
            zMax: zMax + padding.z
        )
    }

    public func union(_ other: BodyBounds) -> BodyBounds {
        BodyBounds(
            xMin: min(xMin, other.xMin),
            xMax: max(xMax, other.xMax),
            yMin: min(yMin, other.yMin),
            yMax: max(yMax, other.yMax),
            zMin: min(zMin, other.zMin),
            zMax: max(zMax, other.zMax)
        )
    }

    public func contains(_ other: BodyBounds, tolerance: Double = 1e-9) -> Bool {
        xMin - tolerance <= other.xMin && other.xMax <= xMax + tolerance
            && yMin - tolerance <= other.yMin && other.yMax <= yMax + tolerance
            && zMin - tolerance <= other.zMin && other.zMax <= zMax + tolerance
    }

    public func intersects(_ other: BodyBounds) -> Bool {
        xMin <= other.xMax && other.xMin <= xMax
            && yMin <= other.yMax && other.yMin <= yMax
            && zMin <= other.zMax && other.zMin <= zMax
    }

    /// The eight corners, in a stable order.
    public static func corners(halfExtent: Vec3) -> [Vec3] {
        var result: [Vec3] = []
        result.reserveCapacity(8)
        for signX in [-1.0, 1.0] {
            for signY in [-1.0, 1.0] {
                for signZ in [-1.0, 1.0] {
                    result.append(
                        Vec3(
                            x: halfExtent.x * signX,
                            y: halfExtent.y * signY,
                            z: halfExtent.z * signZ
                        )
                    )
                }
            }
        }
        return result
    }

    /// The axis-aligned box enclosing a set of points.
    public static func enclosing(points: [Vec3]) -> BodyBounds? {
        guard let first = points.first else { return nil }
        var bounds = BodyBounds(
            xMin: first.x, xMax: first.x,
            yMin: first.y, yMax: first.y,
            zMin: first.z, zMax: first.z
        )
        for point in points.dropFirst() {
            bounds.xMin = min(bounds.xMin, point.x)
            bounds.xMax = max(bounds.xMax, point.x)
            bounds.yMin = min(bounds.yMin, point.y)
            bounds.yMax = max(bounds.yMax, point.y)
            bounds.zMin = min(bounds.zMin, point.z)
            bounds.zMax = max(bounds.zMax, point.z)
        }
        return bounds
    }

    public static func union(of boundsList: [BodyBounds]) -> BodyBounds? {
        guard var result = boundsList.first else { return nil }
        for bounds in boundsList.dropFirst() {
            result = result.union(bounds)
        }
        return result
    }
}
