import Foundation

/// Exports the resolved, visible geometry as a binary STL mesh — for
/// cross-checking this model's geometry against another EM tool (e.g. CST)
/// that can import STL.
///
/// Lengths are written exactly as resolved, in the project's own length
/// unit — not converted to metres the way the solver export is. STL carries
/// no unit metadata, so whoever imports this file needs to be told which
/// unit these numbers are in (the project's `lengthUnit`).
public enum STLExporter {
    public struct Triangle: Hashable, Sendable {
        public let v0: Vec3
        public let v1: Vec3
        public let v2: Vec3
    }

    /// Every visible body's surface, in world coordinates, project units.
    /// `segments` controls how finely a cylinder's round cross-section is
    /// tessellated.
    public static func triangles(for bodies: [ResolvedBody], segments: Int = 32) -> [Triangle] {
        var result: [Triangle] = []
        for body in bodies where body.isVisible {
            let local = localTriangles(for: body.shape, segments: segments)
            let matrix = body.rotationMatrix
            for triangle in local {
                result.append(
                    Triangle(
                        v0: matrix.apply(to: triangle.v0.scaled(by: body.scale)) + body.position,
                        v1: matrix.apply(to: triangle.v1.scaled(by: body.scale)) + body.position,
                        v2: matrix.apply(to: triangle.v2.scaled(by: body.scale)) + body.position
                    )
                )
            }
        }
        return result
    }

    public static func encode(resolved: ResolvedModel, segments: Int = 32) -> Data {
        encodeBinary(triangles(for: resolved.bodies, segments: segments))
    }

    // MARK: - Binary STL

    /// The standard 80-byte-header / 4-byte-count / 50-bytes-per-triangle
    /// binary format (12 floats + a 2-byte attribute count, little-endian).
    public static func encodeBinary(_ triangles: [Triangle]) -> Data {
        var data = Data(capacity: 80 + 4 + triangles.count * 50)
        data.append(Data(repeating: 0, count: 80))
        appendUInt32LE(UInt32(triangles.count), to: &data)

        for triangle in triangles {
            let normal = faceNormal(triangle)
            appendFloatLE(normal.x, to: &data)
            appendFloatLE(normal.y, to: &data)
            appendFloatLE(normal.z, to: &data)
            for v in [triangle.v0, triangle.v1, triangle.v2] {
                appendFloatLE(v.x, to: &data)
                appendFloatLE(v.y, to: &data)
                appendFloatLE(v.z, to: &data)
            }
            data.append(0)
            data.append(0)
        }
        return data
    }

    /// Outward unit normal from the (CCW, right-hand-rule) vertex winding —
    /// computed from the actual transformed vertices rather than carried
    /// through from local space, so it comes out correct regardless of any
    /// rotation or (mirroring) negative scale applied to the body.
    static func faceNormal(_ t: Triangle) -> Vec3 {
        let e1 = t.v1 - t.v0
        let e2 = t.v2 - t.v0
        let n = Vec3(
            x: e1.y * e2.z - e1.z * e2.y,
            y: e1.z * e2.x - e1.x * e2.z,
            z: e1.x * e2.y - e1.y * e2.x
        )
        let length = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
        guard length > 0 else { return .zero }
        return Vec3(x: n.x / length, y: n.y / length, z: n.z / length)
    }

    private static func appendFloatLE(_ value: Double, to data: inout Data) {
        withUnsafeBytes(of: Float(value).bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: - Local mesh generation (centered at the body's own origin, pre-transform)

    static func localTriangles(for shape: ResolvedShape, segments: Int) -> [Triangle] {
        switch shape {
        case .box(let size):
            return boxTriangles(size: size)
        case .sheet(let size, let normal):
            if size[normal] == 0 {
                return planeTriangles(size: size, normal: normal)
            }
            return boxTriangles(size: size)
        case .cylinder(let radius, let begin, let end, let axis):
            return cylinderTriangles(radius: radius, length: abs(end - begin), axis: axis, segments: max(8, segments))
        }
    }

    /// Centered at the origin, spanning ±size/2 on each axis — the same
    /// convention `ResolvedShape.localSize` uses.
    static func boxTriangles(size: Vec3) -> [Triangle] {
        let hx = size.x / 2, hy = size.y / 2, hz = size.z / 2
        let p000 = Vec3(x: -hx, y: -hy, z: -hz)
        let p100 = Vec3(x: hx, y: -hy, z: -hz)
        let p110 = Vec3(x: hx, y: hy, z: -hz)
        let p010 = Vec3(x: -hx, y: hy, z: -hz)
        let p001 = Vec3(x: -hx, y: -hy, z: hz)
        let p101 = Vec3(x: hx, y: -hy, z: hz)
        let p111 = Vec3(x: hx, y: hy, z: hz)
        let p011 = Vec3(x: -hx, y: hy, z: hz)

        var triangles: [Triangle] = []
        func quad(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3) {
            triangles.append(Triangle(v0: a, v1: b, v2: c))
            triangles.append(Triangle(v0: a, v1: c, v2: d))
        }
        quad(p010, p110, p100, p000) // -Z
        quad(p001, p101, p111, p011) // +Z
        quad(p000, p100, p101, p001) // -Y
        quad(p011, p111, p110, p010) // +Y
        quad(p010, p000, p001, p011) // -X
        quad(p100, p110, p111, p101) // +X
        return triangles
    }

    /// A zero-thickness sheet has no "inside," so both faces are emitted —
    /// otherwise it would be invisible from one side in most STL viewers.
    static func planeTriangles(size: Vec3, normal: Axis) -> [Triangle] {
        let (first, second) = normal.perpendicular
        let hw = size[first] / 2, hd = size[second] / 2

        func point(_ w: Double, _ d: Double) -> Vec3 {
            var v = Vec3.zero
            v[first] = w
            v[second] = d
            return v
        }

        let a = point(-hw, -hd), b = point(hw, -hd), c = point(hw, hd), d = point(-hw, hd)
        return [
            Triangle(v0: a, v1: b, v2: c),
            Triangle(v0: a, v1: c, v2: d),
            Triangle(v0: a, v1: c, v2: b),
            Triangle(v0: a, v1: d, v2: c)
        ]
    }

    /// Centered at the origin, spanning ±length/2 along `axis`.
    static func cylinderTriangles(radius: Double, length: Double, axis: Axis, segments: Int) -> [Triangle] {
        let (u, v) = axis.perpendicular
        let half = length / 2

        var bottom: [Vec3] = []
        var top: [Vec3] = []
        bottom.reserveCapacity(segments)
        top.reserveCapacity(segments)
        for i in 0..<segments {
            let theta = 2 * Double.pi * Double(i) / Double(segments)
            var p = Vec3.zero
            p[u] = radius * cos(theta)
            p[v] = radius * sin(theta)
            p[axis] = -half
            bottom.append(p)
            var q = p
            q[axis] = half
            top.append(q)
        }

        var bottomCenter = Vec3.zero
        bottomCenter[axis] = -half
        var topCenter = Vec3.zero
        topCenter[axis] = half

        var triangles: [Triangle] = []
        for i in 0..<segments {
            let j = (i + 1) % segments
            // Side wall.
            triangles.append(Triangle(v0: bottom[i], v1: bottom[j], v2: top[j]))
            triangles.append(Triangle(v0: bottom[i], v1: top[j], v2: top[i]))
            // Caps.
            triangles.append(Triangle(v0: bottomCenter, v1: bottom[j], v2: bottom[i]))
            triangles.append(Triangle(v0: topCenter, v1: top[i], v2: top[j]))
        }
        return triangles
    }
}
