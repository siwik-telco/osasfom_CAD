import Foundation

/// Constructive solid geometry on triangle meshes — the *display* half of
/// boolean support.
///
/// The solver never looks at this. It samples `ShapeContainment`, which stays
/// analytic and so keeps a cylinder a true cylinder. What this produces is a
/// surface mesh for the viewport and for STL export, where a hole has to be
/// visible rather than merely implied.
///
/// The algorithm is the standard BSP formulation popularised by csg.js: clip
/// each solid's polygons against the other's tree, then reassemble. It
/// assumes closed, non-self-intersecting input, which is exactly what these
/// primitives are. Inputs here are small — 12 triangles for a box, ~128 for a
/// cylinder — so the tree stays shallow and the whole evaluation is
/// imperceptible.
public enum MeshCSG {

    /// Distance under which a point counts as lying *on* a plane rather than
    /// to one side. Project units (typically mm), so this is a micron-scale
    /// threshold: tight enough to keep coincident faces from being split into
    /// slivers, loose enough to absorb the rounding two primitives sharing an
    /// exact coordinate will produce.
    static let epsilon = 1e-9

    // MARK: - Plane

    struct Plane {
        var normal: Vec3
        var w: Double

        init(normal: Vec3, w: Double) {
            self.normal = normal
            self.w = w
        }

        /// `nil` when the three points are collinear, i.e. a degenerate face
        /// that carries no orientation and must be dropped rather than
        /// producing a NaN normal.
        init?(a: Vec3, b: Vec3, c: Vec3) {
            guard let normal = (b - a).cross(c - a).normalized else { return nil }
            self.normal = normal
            self.w = normal.dot(a)
        }

        var flipped: Plane { Plane(normal: normal * -1, w: -w) }
    }

    private enum Location: Int {
        case coplanar = 0
        case front = 1
        case back = 2
        case spanning = 3
    }

    // MARK: - Polygon

    /// A convex, planar face. Splitting keeps polygons rather than
    /// re-triangulating at every step, which avoids piling up slivers; the
    /// fan back to triangles happens once, at the end.
    struct Polygon {
        var vertices: [Vec3]
        var plane: Plane

        init?(vertices: [Vec3]) {
            guard vertices.count >= 3, let plane = Plane(a: vertices[0], b: vertices[1], c: vertices[2]) else {
                return nil
            }
            self.vertices = vertices
            self.plane = plane
        }

        init(vertices: [Vec3], plane: Plane) {
            self.vertices = vertices
            self.plane = plane
        }

        var flipped: Polygon {
            Polygon(vertices: vertices.reversed(), plane: plane.flipped)
        }

        var triangles: [STLExporter.Triangle] {
            guard vertices.count >= 3 else { return [] }
            return (1..<(vertices.count - 1)).map { index in
                STLExporter.Triangle(v0: vertices[0], v1: vertices[index], v2: vertices[index + 1])
            }
        }
    }

    /// The four groups a plane can cut a polygon into. Returned rather than
    /// written through `inout` buckets because callers legitimately want to
    /// funnel two of the groups into the same array, which aliasing rules
    /// forbid.
    private struct Split {
        var coplanarFront: [Polygon] = []
        var coplanarBack: [Polygon] = []
        var front: [Polygon] = []
        var back: [Polygon] = []
    }

    /// Splits `polygon` by `plane`. Coplanar faces are sorted by whether they
    /// face the same way as the plane, which is what lets the clip step keep
    /// exactly one copy of a shared surface instead of two overlapping ones.
    private static func split(_ polygon: Polygon, by plane: Plane) -> Split {
        var result = Split()
        var polygonType = 0
        var types: [Location] = []
        types.reserveCapacity(polygon.vertices.count)

        for vertex in polygon.vertices {
            let distance = plane.normal.dot(vertex) - plane.w
            let type: Location = distance < -epsilon ? .back : (distance > epsilon ? .front : .coplanar)
            polygonType |= type.rawValue
            types.append(type)
        }

        switch Location(rawValue: polygonType) ?? .spanning {
        case .coplanar:
            if plane.normal.dot(polygon.plane.normal) > 0 {
                result.coplanarFront.append(polygon)
            } else {
                result.coplanarBack.append(polygon)
            }
        case .front:
            result.front.append(polygon)
        case .back:
            result.back.append(polygon)
        case .spanning:
            var frontVertices: [Vec3] = []
            var backVertices: [Vec3] = []
            let count = polygon.vertices.count
            for i in 0..<count {
                let j = (i + 1) % count
                let ti = types[i], tj = types[j]
                let vi = polygon.vertices[i], vj = polygon.vertices[j]

                if ti != .back { frontVertices.append(vi) }
                if ti != .front { backVertices.append(vi) }

                if (ti.rawValue | tj.rawValue) == Location.spanning.rawValue {
                    let numerator = plane.w - plane.normal.dot(vi)
                    let denominator = plane.normal.dot(vj - vi)
                    guard denominator != 0 else { continue }
                    let crossing = vi.interpolated(to: vj, by: numerator / denominator)
                    frontVertices.append(crossing)
                    backVertices.append(crossing)
                }
            }
            if frontVertices.count >= 3 {
                result.front.append(Polygon(vertices: frontVertices, plane: polygon.plane))
            }
            if backVertices.count >= 3 {
                result.back.append(Polygon(vertices: backVertices, plane: polygon.plane))
            }
        }
        return result
    }

    // MARK: - BSP node

    private final class Node {
        var plane: Plane?
        var front: Node?
        var back: Node?
        var polygons: [Polygon] = []

        init(_ polygons: [Polygon] = []) {
            build(polygons)
        }

        func invert() {
            polygons = polygons.map(\.flipped)
            plane = plane?.flipped
            front?.invert()
            back?.invert()
            swap(&front, &back)
        }

        /// The polygons of `input` that lie outside this solid.
        func clip(_ input: [Polygon]) -> [Polygon] {
            guard let plane else { return input }

            var frontPolygons: [Polygon] = []
            var backPolygons: [Polygon] = []
            for polygon in input {
                let pieces = split(polygon, by: plane)
                // A face lying in this plane goes with whichever side it
                // faces, so a shared surface survives exactly once.
                frontPolygons += pieces.coplanarFront + pieces.front
                backPolygons += pieces.coplanarBack + pieces.back
            }

            let clippedFront = front.map { $0.clip(frontPolygons) } ?? frontPolygons
            // No back child means everything behind this plane is solid, so
            // it is discarded rather than carried through.
            let clippedBack = back.map { $0.clip(backPolygons) } ?? []
            return clippedFront + clippedBack
        }

        /// Removes everything of ours that sits inside `other`.
        func clipTo(_ other: Node) {
            polygons = other.clip(polygons)
            front?.clipTo(other)
            back?.clipTo(other)
        }

        var allPolygons: [Polygon] {
            polygons + (front?.allPolygons ?? []) + (back?.allPolygons ?? [])
        }

        func build(_ input: [Polygon]) {
            guard !input.isEmpty else { return }
            let splitPlane = plane ?? input[0].plane
            plane = splitPlane

            var frontPolygons: [Polygon] = []
            var backPolygons: [Polygon] = []
            for polygon in input {
                let pieces = split(polygon, by: splitPlane)
                // Both coplanar groups belong to this node itself.
                polygons += pieces.coplanarFront + pieces.coplanarBack
                frontPolygons += pieces.front
                backPolygons += pieces.back
            }

            if !frontPolygons.isEmpty {
                let node = front ?? Node()
                node.build(frontPolygons)
                front = node
            }
            if !backPolygons.isEmpty {
                let node = back ?? Node()
                node.build(backPolygons)
                back = node
            }
        }
    }

    // MARK: - Operations

    public static func union(_ a: [STLExporter.Triangle], _ b: [STLExporter.Triangle]) -> [STLExporter.Triangle] {
        evaluate(a, b) { nodeA, nodeB in
            nodeA.clipTo(nodeB)
            nodeB.clipTo(nodeA)
            nodeB.invert()
            nodeB.clipTo(nodeA)
            nodeB.invert()
            nodeA.build(nodeB.allPolygons)
        }
    }

    public static func subtract(_ a: [STLExporter.Triangle], _ b: [STLExporter.Triangle]) -> [STLExporter.Triangle] {
        evaluate(a, b) { nodeA, nodeB in
            nodeA.invert()
            nodeA.clipTo(nodeB)
            nodeB.clipTo(nodeA)
            nodeB.invert()
            nodeB.clipTo(nodeA)
            nodeB.invert()
            nodeA.build(nodeB.allPolygons)
            nodeA.invert()
        }
    }

    public static func intersect(_ a: [STLExporter.Triangle], _ b: [STLExporter.Triangle]) -> [STLExporter.Triangle] {
        evaluate(a, b) { nodeA, nodeB in
            nodeA.invert()
            nodeB.clipTo(nodeA)
            nodeB.invert()
            nodeA.clipTo(nodeB)
            nodeB.clipTo(nodeA)
            nodeA.build(nodeB.allPolygons)
            nodeA.invert()
        }
    }

    public static func apply(
        _ kind: BooleanKind,
        base: [STLExporter.Triangle],
        tool: [STLExporter.Triangle]
    ) -> [STLExporter.Triangle] {
        switch kind {
        case .add: return union(base, tool)
        case .subtract: return subtract(base, tool)
        case .trim: return intersect(base, tool)
        }
    }

    private static func evaluate(
        _ a: [STLExporter.Triangle],
        _ b: [STLExporter.Triangle],
        _ combine: (Node, Node) -> Void
    ) -> [STLExporter.Triangle] {
        // Two empty operands, or an operand that degenerated to nothing, would
        // otherwise build an empty tree whose result is silently wrong; short
        // circuit instead so the caller keeps whichever side still has volume.
        guard !a.isEmpty else { return [] }
        guard !b.isEmpty else { return a }

        let nodeA = Node(polygons(a))
        let nodeB = Node(polygons(b))
        combine(nodeA, nodeB)
        return nodeA.allPolygons.flatMap(\.triangles)
    }

    private static func polygons(_ triangles: [STLExporter.Triangle]) -> [Polygon] {
        triangles.compactMap { Polygon(vertices: [$0.v0, $0.v1, $0.v2]) }
    }
}
