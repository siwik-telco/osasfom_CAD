import Foundation

/// Resolves a world-space point (e.g. a viewport click) into a snap point on
/// a body's own local shape — its nearest face's center, or the midpoint of
/// that face's nearest edge, whichever the point landed closer to.
///
/// This works in the body's local (unrotated, unscaled) frame, so it stays
/// correct for a rotated body — unlike snapping against the world-space
/// axis-aligned bounding box, which is not the shape of the body's true
/// (rotated) faces once it has any rotation, and is not even the right
/// shape for a cylinder's curved side.
public enum BodySnapPoint {
    /// The world-space snap point nearest `worldPoint` on `body`'s surface.
    public static func nearest(on body: ResolvedBody, to worldPoint: Vec3) -> Vec3 {
        let relative = worldPoint - body.position
        let unrotated = body.rotationMatrix.transposed.apply(to: relative)
        let scale = body.scale
        let local = Vec3(
            x: scale.x != 0 ? unrotated.x / scale.x : unrotated.x,
            y: scale.y != 0 ? unrotated.y / scale.y : unrotated.y,
            z: scale.z != 0 ? unrotated.z / scale.z : unrotated.z
        )

        let localSnap: Vec3
        switch body.shape {
        case .box, .sheet:
            localSnap = boxSnapPoint(localSize: body.shape.localSize, local: local)
        case .cylinder(let radius, let begin, let end, let axis):
            localSnap = cylinderSnapPoint(radius: radius, length: abs(end - begin), axis: axis, local: local)
        }

        let scaledLocal = Vec3(x: localSnap.x * scale.x, y: localSnap.y * scale.y, z: localSnap.z * scale.z)
        return body.rotationMatrix.apply(to: scaledLocal) + body.position
    }

    /// For a box/sheet: picks the face whose axis the point sits nearest the
    /// surface of, then within that face snaps to whichever is closer — the
    /// face's center, or the midpoint of its nearest edge. A zero-thickness
    /// sheet only has one real face axis (its normal — front and back are
    /// the same plane), so that's forced rather than chosen by the general
    /// ratio test, which would otherwise degrade to picking an arbitrary
    /// in-plane axis for a flat shape.
    static func boxSnapPoint(localSize: Vec3, local: Vec3) -> Vec3 {
        let faceAxis = Axis.allCases.first { localSize[$0] == 0 } ?? bestRatioAxis(localSize: localSize, local: local)

        let (perp1, perp2) = faceAxis.perpendicular
        let half1 = localSize[perp1] / 2
        let half2 = localSize[perp2] / 2
        let click = (local[perp1], local[perp2])

        // Candidates within the face rectangle: its center, and the midpoint
        // of each of its 4 edges.
        let candidates: [(Double, Double)] = [
            (0, 0),
            (half1, 0), (-half1, 0),
            (0, half2), (0, -half2)
        ]
        let nearest = candidates.min { squaredDistance($0, click) < squaredDistance($1, click) } ?? (0, 0)

        var result = Vec3.zero
        result[faceAxis] = local[faceAxis] >= 0 ? localSize[faceAxis] / 2 : -localSize[faceAxis] / 2
        result[perp1] = nearest.0
        result[perp2] = nearest.1
        return result
    }

    private static func bestRatioAxis(localSize: Vec3, local: Vec3) -> Axis {
        var bestAxis = Axis.x
        var bestRatio = -Double.infinity
        for axis in Axis.allCases {
            let half = localSize[axis] / 2
            guard half > 0 else { continue }
            let ratio = abs(local[axis]) / half
            if ratio > bestRatio {
                bestRatio = ratio
                bestAxis = axis
            }
        }
        return bestAxis
    }

    /// For a cylinder: end-cap hits (the point is nearer the flat end than
    /// the curved side) snap to that end's axis center, or — if the point
    /// landed nearer the rim than the center — to the rim point at the
    /// clicked angle. A curved-side hit has no single natural point, so it
    /// projects onto the axis at that height, the unambiguous choice for
    /// something like a radial probe feed.
    static func cylinderSnapPoint(radius: Double, length: Double, axis: Axis, local: Vec3) -> Vec3 {
        let (perp1, perp2) = axis.perpendicular
        let half = length / 2
        let radial = (local[perp1] * local[perp1] + local[perp2] * local[perp2]).squareRoot()

        let distanceToCap = abs(half - abs(local[axis]))
        let distanceToSide = abs(radius - radial)

        var result = Vec3.zero
        if distanceToCap <= distanceToSide {
            result[axis] = local[axis] >= 0 ? half : -half
            if radial > radius / 2, radial > 0 {
                let rimScale = radius / radial
                result[perp1] = local[perp1] * rimScale
                result[perp2] = local[perp2] * rimScale
            }
        } else {
            result[axis] = max(-half, min(half, local[axis]))
        }
        return result
    }

    private static func squaredDistance(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let dx = a.0 - b.0, dy = a.1 - b.1
        return dx * dx + dy * dy
    }
}
