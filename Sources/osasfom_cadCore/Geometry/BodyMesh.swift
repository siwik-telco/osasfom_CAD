import Foundation

/// Surface triangles for a resolved body, with its boolean history applied.
///
/// One place builds this so the viewport and the STL export can never drift
/// apart, and so the "no booleans" case stays byte-for-byte what it always
/// was: a body without a history skips the CSG evaluator entirely rather than
/// round-tripping through it.
public enum BodyMesh {

    /// Triangles in world coordinates, project units.
    public static func worldTriangles(for body: ResolvedBody, segments: Int = 32) -> [STLExporter.Triangle] {
        let base = transformed(
            STLExporter.localTriangles(for: body.shape, segments: segments),
            position: body.position,
            rotationDegrees: body.rotationDegrees,
            scale: body.scale
        )

        // A zero-thickness sheet is a surface, not a solid: a BSP boolean has
        // no inside to work with and would return an empty or inverted mesh.
        // It is drawn whole, and the resolver warns that it will be.
        guard !body.booleans.isEmpty, body.shape.degenerateAxis == nil else { return base }

        return body.booleans.reduce(base) { result, step in
            let toolTriangles = transformed(
                STLExporter.localTriangles(for: step.shape, segments: segments),
                position: step.position,
                rotationDegrees: step.rotationDegrees,
                scale: step.scale
            )
            return MeshCSG.apply(step.kind, base: result, tool: toolTriangles)
        }
    }

    /// Triangles in the body's own unrotated, unscaled frame — what the
    /// renderer wants, because the scene node re-applies the body's placement
    /// itself.
    public static func localTriangles(for body: ResolvedBody, segments: Int = 32) -> [STLExporter.Triangle] {
        guard !body.booleans.isEmpty, body.shape.degenerateAxis == nil else {
            return STLExporter.localTriangles(for: body.shape, segments: segments)
        }

        let world = worldTriangles(for: body, segments: segments)
        let inverseRotation = Matrix3.euler(degrees: body.rotationDegrees).transposed

        func toLocal(_ v: Vec3) -> Vec3 {
            let unrotated = inverseRotation.apply(to: v - body.position)
            return Vec3(x: unrotated.x / body.scale.x, y: unrotated.y / body.scale.y, z: unrotated.z / body.scale.z)
        }

        let local = world.map { STLExporter.Triangle(v0: toLocal($0.v0), v1: toLocal($0.v1), v2: toLocal($0.v2)) }
        // Undoing a mirroring scale turns the surface inside out, which would
        // light every face from the wrong side. Flip the winding back.
        return isMirroring(body.scale) ? local.map(reversed) : local
    }

    /// Applies a shape's own placement to its local triangles.
    private static func transformed(
        _ triangles: [STLExporter.Triangle],
        position: Vec3,
        rotationDegrees: Vec3,
        scale: Vec3
    ) -> [STLExporter.Triangle] {
        let matrix = Matrix3.euler(degrees: rotationDegrees)
        func toWorld(_ v: Vec3) -> Vec3 { matrix.apply(to: v.scaled(by: scale)) + position }

        let world = triangles.map { STLExporter.Triangle(v0: toWorld($0.v0), v1: toWorld($0.v1), v2: toWorld($0.v2)) }
        // A negative scale component mirrors the shape, reversing which side
        // of every face points outward. The BSP boolean reads that as "inside
        // out" and would cut away the complement of what was asked for.
        return isMirroring(scale) ? world.map(reversed) : world
    }

    private static func isMirroring(_ scale: Vec3) -> Bool {
        scale.x * scale.y * scale.z < 0
    }

    private static func reversed(_ t: STLExporter.Triangle) -> STLExporter.Triangle {
        STLExporter.Triangle(v0: t.v0, v1: t.v2, v2: t.v1)
    }
}
