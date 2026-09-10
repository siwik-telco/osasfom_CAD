import Foundation

/// Exact point-in-solid tests, including a body's boolean history.
///
/// This is the authority on "is this point inside this body". The FDTD
/// material lookup samples it once per cell, so it has to agree with what the
/// viewport draws — but unlike the viewport it stays analytic, so a cylinder
/// is a true cylinder here rather than the 32-sided prism a triangulated
/// mesh has to settle for. `MeshCSG` is the display counterpart; this is the
/// one the physics sees.
public enum ShapeContainment {
    /// A point sitting exactly on a body's own declared edge — the normal
    /// case for a port meant to be flush with a board edge — can land a few
    /// ULPs *outside* it once its coordinate has been through the
    /// centre/half-extent subtraction (e.g. `-lg/2` and `-l/2` combining into
    /// a half-extent that differs from the point itself by ~1e-15). A bare
    /// `<=` then silently drops the body that was meant to own that point in
    /// favour of whatever lies underneath. This absorbs that, in project
    /// units, mirroring the tolerance `BodyBounds.contains` already applies.
    public static let tolerance = 1e-9

    /// Whether `localPoint` — already in the shape's own unrotated, unscaled
    /// frame, centred on its origin — is inside `shape`.
    public static func contains(_ shape: ResolvedShape, localPoint local: Vec3) -> Bool {
        let tol = tolerance
        switch shape {
        case .box(let size):
            return abs(local.x) <= size.x / 2 + tol
                && abs(local.y) <= size.y / 2 + tol
                && abs(local.z) <= size.z / 2 + tol

        case .sheet(let size, _):
            // A zero-thickness sheet is a legal FDTD construct: it stays a
            // surface here rather than being widened to a cell, because the
            // mesher puts a grid line exactly on it via snapToBodyEdges.
            return abs(local.x) <= max(size.x, 0) / 2 + tol
                && abs(local.y) <= max(size.y, 0) / 2 + tol
                && abs(local.z) <= max(size.z, 0) / 2 + tol

        case .cylinder(let radius, let begin, let end, let axis):
            let halfLength = abs(end - begin) / 2
            guard abs(local[axis]) <= halfLength + tol else { return false }
            let (first, second) = axis.perpendicular
            let radial = local[first] * local[first] + local[second] * local[second]
            return radial <= (radius + tol) * (radius + tol)

        case .mesh(let mesh):
            // No analytic form to widen by `tol`: an imported surface is
            // whatever the triangles say. `TriangleMesh` ray-casts through a
            // BVH, which is what keeps this affordable at the tens of
            // millions of samples an FDTD run takes.
            return mesh.contains(local)
        }
    }

    /// Moves a world point into a shape's local frame by undoing, in order,
    /// its translation, rotation and scale.
    public static func toLocal(
        _ point: Vec3,
        position: Vec3,
        rotationDegrees: Vec3,
        scale: Vec3
    ) -> Vec3 {
        let translated = point - position
        let unrotated = Matrix3.euler(degrees: rotationDegrees).transposed.apply(to: translated)
        return Vec3(x: unrotated.x / scale.x, y: unrotated.y / scale.y, z: unrotated.z / scale.z)
    }

    public static func contains(
        _ shape: ResolvedShape,
        position: Vec3,
        rotationDegrees: Vec3,
        scale: Vec3,
        worldPoint: Vec3
    ) -> Bool {
        contains(
            shape,
            localPoint: toLocal(worldPoint, position: position, rotationDegrees: rotationDegrees, scale: scale)
        )
    }

    public static func contains(_ operation: ResolvedBooleanOperation, worldPoint: Vec3) -> Bool {
        contains(
            operation.shape,
            position: operation.position,
            rotationDegrees: operation.rotationDegrees,
            scale: operation.scale,
            worldPoint: worldPoint
        )
    }

    /// Whether `worldPoint` is inside `body` *after* its boolean history.
    ///
    /// Steps fold in list order, so `subtract` then `add` puts material back
    /// into the hole the subtract made — the same left-to-right reading the
    /// inspector shows.
    public static func contains(_ body: ResolvedBody, worldPoint: Vec3) -> Bool {
        var inside = contains(
            body.shape,
            position: body.position,
            rotationDegrees: body.rotationDegrees,
            scale: body.scale,
            worldPoint: worldPoint
        )

        for operation in body.booleans {
            let inTool = contains(operation, worldPoint: worldPoint)
            switch operation.kind {
            case .add: inside = inside || inTool
            case .subtract: inside = inside && !inTool
            case .trim: inside = inside && inTool
            }
        }
        return inside
    }
}
