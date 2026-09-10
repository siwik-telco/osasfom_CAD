import Foundation

/// An imported triangle mesh — the payload behind `Primitive.mesh`.
///
/// Held by reference on purpose. `CADModelState` is a value type that the undo
/// stack copies on every edit and that SwiftUI compares on every render, and a
/// mesh is three to five orders of magnitude larger than any parametric
/// primitive: copying or walking it there would dominate both. Identity is a
/// `UUID` assigned at construction and carried through the project file, which
/// makes `==` and `hash` O(1). That is exact rather than approximate because a
/// mesh is never edited in place — any change produces a new mesh with a new
/// id.
///
/// Triangles are stored in the body's own frame, **centred on its origin**,
/// the same convention every other primitive uses (see
/// `STLExporter.localTriangles`). `STLImporter` recentres on import and hands
/// the offset to the body's position, so the model still lands where the file
/// said it was.
public final class TriangleMesh: Hashable, Sendable, Codable {
    public let id: UUID
    /// Surface triangles, local frame, project units.
    public let triangles: [STLExporter.Triangle]
    /// Axis-aligned box of `triangles`. Centred on the origin by construction.
    public let bounds: BodyBounds
    /// True when every edge is shared by exactly two triangles.
    ///
    /// A watertight mesh divides space cleanly, so one ray settles
    /// inside-vs-outside. An open one does not, and `contains` then votes
    /// across several rays rather than trusting a single parity count — see
    /// `rayDirections`.
    public let isWatertight: Bool

    private let bvh: TriangleBVH

    /// Fails only on an empty triangle list — a mesh with no surface has no
    /// inside, and every downstream consumer would have to special-case it.
    public init?(id: UUID = UUID(), triangles: [STLExporter.Triangle]) {
        guard !triangles.isEmpty else { return nil }
        guard let bounds = BodyBounds.enclosing(
            points: triangles.flatMap { [$0.v0, $0.v1, $0.v2] }
        ) else { return nil }

        self.id = id
        self.triangles = triangles
        self.bounds = bounds
        self.isWatertight = TriangleMesh.isClosed(triangles)
        self.bvh = TriangleBVH(triangles: triangles)
    }

    public var triangleCount: Int { triangles.count }

    // MARK: - Point in solid

    /// Ray directions used for the parity test.
    ///
    /// Deliberately not axis-aligned and mutually unrelated. A ray along an
    /// axis from a grid-aligned sample point lands exactly on a shared edge or
    /// a coplanar face constantly in a mesh exported from CAD, and each of
    /// those is a parity count that could go either way.
    private static let rayDirections: [Vec3] = [
        Vec3(x: 0.3517, y: 0.7563, z: 0.5512),
        Vec3(x: 0.8161, y: -0.2371, z: 0.5271),
        Vec3(x: -0.4623, y: 0.6172, z: 0.6371)
    ].map { $0.normalized ?? Vec3(x: 0, y: 0, z: 1) }

    /// Whether `point` (local frame) is inside the surface.
    ///
    /// Odd-even ray parity. A closed mesh needs one ray; an open one gets the
    /// majority of three, which does not make a hole watertight but keeps a
    /// single unlucky ray from carving a spurious channel through the solid.
    public func contains(_ point: Vec3) -> Bool {
        guard bounds.contains(point) else { return false }

        if isWatertight {
            return bvh.crossings(from: point, direction: Self.rayDirections[0], triangles: triangles) % 2 == 1
        }

        var inside = 0
        for direction in Self.rayDirections
        where bvh.crossings(from: point, direction: direction, triangles: triangles) % 2 == 1 {
            inside += 1
        }
        return inside * 2 > Self.rayDirections.count
    }

    // MARK: - Watertightness

    /// Every edge shared by exactly two triangles, compared on exact vertex
    /// coordinates. STL has no vertex table — each triangle repeats its
    /// corners verbatim — so an exporter that wrote the same corner twice
    /// writes the same bits twice, and exact comparison is the right test.
    private static func isClosed(_ triangles: [STLExporter.Triangle]) -> Bool {
        struct Edge: Hashable {
            let a: Vec3
            let b: Vec3

            init(_ first: Vec3, _ second: Vec3) {
                // Undirected: order the pair so the two triangles sharing an
                // edge produce the same key despite opposite winding.
                if (first.x, first.y, first.z) <= (second.x, second.y, second.z) {
                    a = first; b = second
                } else {
                    a = second; b = first
                }
            }
        }

        var counts: [Edge: Int] = [:]
        counts.reserveCapacity(triangles.count * 3)
        for triangle in triangles {
            counts[Edge(triangle.v0, triangle.v1), default: 0] += 1
            counts[Edge(triangle.v1, triangle.v2), default: 0] += 1
            counts[Edge(triangle.v2, triangle.v0), default: 0] += 1
        }
        return counts.values.allSatisfy { $0 == 2 }
    }

    // MARK: - Hashable

    public static func == (lhs: TriangleMesh, rhs: TriangleMesh) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Codable

    /// Vertices ride as one base64 blob of little-endian `Float32`, nine per
    /// triangle. STL is a float32 format, so nothing is lost that the file did
    /// not already lose, and a hundred thousand triangles stay one JSON string
    /// instead of nine hundred thousand pretty-printed numbers.
    private enum CodingKeys: String, CodingKey {
        case id, triangleCount, vertices
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let count = try container.decode(Int.self, forKey: .triangleCount)
        let blob = try container.decode(Data.self, forKey: .vertices)

        let expected = count * 9 * MemoryLayout<Float32>.size
        guard count > 0, blob.count == expected else {
            throw DecodingError.dataCorruptedError(
                forKey: .vertices,
                in: container,
                debugDescription: "Expected \(expected) bytes for \(count) triangles, found \(blob.count)."
            )
        }

        var floats = [Float32](repeating: 0, count: count * 9)
        _ = floats.withUnsafeMutableBytes { blob.copyBytes(to: $0) }
        if !TriangleMesh.isLittleEndianHost {
            for index in floats.indices {
                floats[index] = Float32(bitPattern: floats[index].bitPattern.byteSwapped)
            }
        }

        var triangles: [STLExporter.Triangle] = []
        triangles.reserveCapacity(count)
        for triangle in 0..<count {
            let base = triangle * 9
            func vertex(_ offset: Int) -> Vec3 {
                Vec3(
                    x: Double(floats[base + offset]),
                    y: Double(floats[base + offset + 1]),
                    z: Double(floats[base + offset + 2])
                )
            }
            triangles.append(STLExporter.Triangle(v0: vertex(0), v1: vertex(3), v2: vertex(6)))
        }

        guard let mesh = TriangleMesh(id: id, triangles: triangles) else {
            throw DecodingError.dataCorruptedError(
                forKey: .vertices,
                in: container,
                debugDescription: "The mesh has no triangles."
            )
        }
        self.init(unchecked: mesh)
    }

    /// Re-wraps an already-built mesh, so the failable designated initialiser
    /// stays the single place that computes bounds, watertightness and the BVH.
    private init(unchecked other: TriangleMesh) {
        self.id = other.id
        self.triangles = other.triangles
        self.bounds = other.bounds
        self.isWatertight = other.isWatertight
        self.bvh = other.bvh
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(triangles.count, forKey: .triangleCount)

        var floats = [Float32]()
        floats.reserveCapacity(triangles.count * 9)
        for triangle in triangles {
            for vertex in [triangle.v0, triangle.v1, triangle.v2] {
                floats.append(Float32(vertex.x))
                floats.append(Float32(vertex.y))
                floats.append(Float32(vertex.z))
            }
        }
        if !TriangleMesh.isLittleEndianHost {
            for index in floats.indices {
                floats[index] = Float32(bitPattern: floats[index].bitPattern.byteSwapped)
            }
        }
        try container.encode(floats.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .vertices)
    }

    private static let isLittleEndianHost = (1 as UInt32).littleEndian == 1
}

// MARK: - BVH

/// A bounding-volume hierarchy over a triangle soup, built once and queried
/// per point.
///
/// The FDTD material provider samples containment on the order of tens of
/// millions of times for a realistic mesh (quarter-cell averaging is roughly
/// 24–48 `material()` calls per cell, times every cell in the domain), so a
/// linear scan over triangles is not an option — it would turn a minutes-long
/// run into a days-long one. Median split on the longest axis: cheap to build,
/// and close enough to a SAH tree for meshes of this size.
struct TriangleBVH: Sendable {
    struct Node: Sendable {
        var minimum: Vec3
        var maximum: Vec3
        /// Index of the right child. The left child is always the next node,
        /// so one field describes both. `0` marks a leaf — no node can have
        /// the root as its right child.
        var rightChild: Int
        var first: Int
        var count: Int

        var isLeaf: Bool { rightChild == 0 }
    }

    private let nodes: [Node]
    /// Triangle indices permuted so every leaf owns one contiguous run.
    private let order: [Int]

    /// Above this many triangles a node is split. Small enough that a leaf
    /// scan stays short, large enough that the tree does not become mostly
    /// interior nodes.
    private static let leafSize = 8

    init(triangles: [STLExporter.Triangle]) {
        var order = Array(triangles.indices)
        var nodes: [Node] = []
        nodes.reserveCapacity(max(1, triangles.count / Self.leafSize * 2))

        let centroids = triangles.map { triangle in
            Vec3(
                x: (triangle.v0.x + triangle.v1.x + triangle.v2.x) / 3,
                y: (triangle.v0.y + triangle.v1.y + triangle.v2.y) / 3,
                z: (triangle.v0.z + triangle.v1.z + triangle.v2.z) / 3
            )
        }

        func boundsOf(_ range: Range<Int>) -> (Vec3, Vec3) {
            var minimum = Vec3(repeating: .infinity)
            var maximum = Vec3(repeating: -.infinity)
            for slot in range {
                let triangle = triangles[order[slot]]
                for vertex in [triangle.v0, triangle.v1, triangle.v2] {
                    minimum = Vec3(
                        x: Swift.min(minimum.x, vertex.x),
                        y: Swift.min(minimum.y, vertex.y),
                        z: Swift.min(minimum.z, vertex.z)
                    )
                    maximum = Vec3(
                        x: Swift.max(maximum.x, vertex.x),
                        y: Swift.max(maximum.y, vertex.y),
                        z: Swift.max(maximum.z, vertex.z)
                    )
                }
            }
            return (minimum, maximum)
        }

        /// Returns the index of the node it appended.
        func build(_ range: Range<Int>) -> Int {
            let (minimum, maximum) = boundsOf(range)
            let index = nodes.count
            nodes.append(Node(minimum: minimum, maximum: maximum, rightChild: 0, first: range.lowerBound, count: range.count))

            guard range.count > Self.leafSize else { return index }

            let extent = Vec3(x: maximum.x - minimum.x, y: maximum.y - minimum.y, z: maximum.z - minimum.z)
            let axis: Axis = extent.x >= extent.y
                ? (extent.x >= extent.z ? .x : .z)
                : (extent.y >= extent.z ? .y : .z)

            let middle = range.lowerBound + range.count / 2
            order[range].withUnsafeMutableBufferPointer { buffer in
                // Partial sort: only the median position has to be correct.
                buffer.sort { centroids[$0][axis] < centroids[$1][axis] }
            }

            // Every centroid on one coordinate — splitting cannot separate
            // them, and recursing would not terminate.
            guard centroids[order[range.lowerBound]][axis] < centroids[order[range.upperBound - 1]][axis] else {
                return index
            }

            _ = build(range.lowerBound..<middle)
            let right = build(middle..<range.upperBound)
            nodes[index].rightChild = right
            nodes[index].count = 0
            return index
        }

        _ = build(0..<order.count)
        self.nodes = nodes
        self.order = order
    }

    /// Number of triangles the ray from `origin` along `direction` crosses.
    func crossings(from origin: Vec3, direction: Vec3, triangles: [STLExporter.Triangle]) -> Int {
        guard !nodes.isEmpty else { return 0 }

        let inverse = Vec3(
            x: 1 / (direction.x == 0 ? .leastNormalMagnitude : direction.x),
            y: 1 / (direction.y == 0 ? .leastNormalMagnitude : direction.y),
            z: 1 / (direction.z == 0 ? .leastNormalMagnitude : direction.z)
        )

        var hits = 0
        var stack = [0]
        stack.reserveCapacity(64)

        while let index = stack.popLast() {
            let node = nodes[index]
            guard Self.rayHitsBox(origin: origin, inverse: inverse, minimum: node.minimum, maximum: node.maximum) else {
                continue
            }
            if node.isLeaf {
                for slot in node.first..<(node.first + node.count)
                where Self.rayHitsTriangle(origin: origin, direction: direction, triangle: triangles[order[slot]]) {
                    hits += 1
                }
            } else {
                stack.append(index + 1)
                stack.append(node.rightChild)
            }
        }
        return hits
    }

    /// Slab test, forward half-line only.
    private static func rayHitsBox(origin: Vec3, inverse: Vec3, minimum: Vec3, maximum: Vec3) -> Bool {
        var near = 0.0
        var far = Double.infinity
        for axis in Axis.allCases {
            let t0 = (minimum[axis] - origin[axis]) * inverse[axis]
            let t1 = (maximum[axis] - origin[axis]) * inverse[axis]
            near = Swift.max(near, Swift.min(t0, t1))
            far = Swift.min(far, Swift.max(t0, t1))
            if near > far { return false }
        }
        return true
    }

    /// Möller–Trumbore, counting only strictly-forward hits.
    ///
    /// Back-face culling is deliberately off: parity counts every surface the
    /// ray passes through, entering and leaving alike.
    private static func rayHitsTriangle(
        origin: Vec3,
        direction: Vec3,
        triangle: STLExporter.Triangle
    ) -> Bool {
        let epsilon = 1e-12
        let edge1 = triangle.v1 - triangle.v0
        let edge2 = triangle.v2 - triangle.v0
        let pvec = direction.cross(edge2)
        let determinant = edge1.dot(pvec)
        guard abs(determinant) > epsilon else { return false } // ray parallel to the face

        let inverseDeterminant = 1 / determinant
        let tvec = origin - triangle.v0
        let u = tvec.dot(pvec) * inverseDeterminant
        guard u >= 0, u <= 1 else { return false }

        let qvec = tvec.cross(edge1)
        let v = direction.dot(qvec) * inverseDeterminant
        guard v >= 0, u + v <= 1 else { return false }

        return edge2.dot(qvec) * inverseDeterminant > epsilon
    }
}
