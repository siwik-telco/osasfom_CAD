import AppKit
import SceneKit
import osasfom_cadCore

/// Builds SceneKit geometry from resolved shapes.
///
/// Kept separate from the scene controller so the "did this change enough to
/// need a new mesh?" signature and the mesh construction stay in step.
public enum SceneGeometryFactory {
    /// Identifies everything that affects the mesh. If two shapes share a
    /// signature the existing `SCNGeometry` can be reused, which is what keeps
    /// incremental updates cheap.
    public struct ShapeSignature: Hashable, Sendable {
        let shape: ResolvedShape
    }

    public static func signature(for shape: ResolvedShape) -> ShapeSignature {
        ShapeSignature(shape: shape)
    }

    public static func makeGeometry(for shape: ResolvedShape) -> SCNGeometry {
        switch shape {
        case .box(let size):
            return SCNBox(
                width: CGFloat(size.x),
                height: CGFloat(size.y),
                length: CGFloat(size.z),
                chamferRadius: 0
            )

        case .cylinder(let radius, let length, _):
            // SCNCylinder is Y-aligned; the node's own rotation orients it.
            return SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))

        case .sheet(let size, let normal):
            guard size[normal] == 0 else {
                return SCNBox(
                    width: CGFloat(size.x),
                    height: CGFloat(size.y),
                    length: CGFloat(size.z),
                    chamferRadius: 0
                )
            }
            // A zero-thickness sheet is a legal FDTD construct, so draw a real
            // surface rather than clamping it to a minimum thickness.
            let (first, second) = normal.perpendicular
            let plane = SCNPlane(width: CGFloat(size[first]), height: CGFloat(size[second]))
            plane.widthSegmentCount = 1
            plane.heightSegmentCount = 1
            return plane
        }
    }

    /// Extra rotation needed to align the primitive's own mesh axes with the
    /// body's axes, before the body's user rotation is applied.
    public static func intrinsicRotation(for shape: ResolvedShape) -> SCNVector3 {
        switch shape {
        case .box:
            return SCNVector3Zero

        case .cylinder(_, _, let axis):
            return vector(axis.rotationFromYAxisDegrees)

        case .sheet(let size, let normal):
            guard size[normal] == 0 else { return SCNVector3Zero }
            // SCNPlane lies in the XY plane facing +Z. These Euler triples map
            // (plane X, plane Y, plane normal) onto (perpendicular.0,
            // perpendicular.1, normal) under SceneKit's Rx·Ry·Rz order, so the
            // width and depth axes match what the spec declares.
            let quarterTurn = CGFloat.pi / 2
            switch normal {
            case .z: return SCNVector3Zero
            case .y: return SCNVector3(-quarterTurn, 0, -quarterTurn)
            case .x: return SCNVector3(0, quarterTurn, quarterTurn)
            }
        }
    }

    public static func makeMaterial(
        color: RGBAColor,
        isSelected: Bool,
        isDoubleSided: Bool
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(color)
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.25
        material.roughness.contents = 0.45
        material.isDoubleSided = isDoubleSided
        material.emission.contents = isSelected
            ? SceneStyle.selection.withAlphaComponent(0.30)
            : NSColor.black
        if color.alpha < 1 {
            material.transparency = CGFloat(color.alpha)
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
        }
        return material
    }

    /// A wireframe box, used for selection, the domain and port markers.
    public static func makeWireBox(
        size: Vec3,
        color: NSColor,
        lineWidthScale: Double = 1.0
    ) -> SCNNode {
        let half = size / 2
        let corners = BodyBounds.corners(halfExtent: half)
        // corners() orders by (signX, signY, signZ) with z innermost.
        let edges: [(Int, Int)] = [
            (0, 1), (2, 3), (4, 5), (6, 7),
            (0, 2), (1, 3), (4, 6), (5, 7),
            (0, 4), (1, 5), (2, 6), (3, 7)
        ]

        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        for (start, end) in edges {
            indices.append(UInt32(vertices.count))
            vertices.append(vector(corners[start]))
            indices.append(UInt32(vertices.count))
            vertices.append(vector(corners[end]))
        }

        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [makeLineMaterial(color: color)]

        let node = SCNNode(geometry: geometry)
        node.scale = SCNVector3(lineWidthScale, lineWidthScale, lineWidthScale)
        return node
    }

    public static func makeLineMaterial(color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        return material
    }

    public static func makeLineNode(from start: Vec3, to end: Vec3, color: NSColor) -> SCNNode {
        let source = SCNGeometrySource(vertices: [vector(start), vector(end)])
        let element = SCNGeometryElement(indices: [UInt32(0), UInt32(1)], primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [makeLineMaterial(color: color)]
        return SCNNode(geometry: geometry)
    }

    public static func vector(_ value: Vec3) -> SCNVector3 {
        SCNVector3(CGFloat(value.x), CGFloat(value.y), CGFloat(value.z))
    }

    public static func degreesToRadians(_ value: Vec3) -> SCNVector3 {
        let factor = CGFloat.pi / 180
        return SCNVector3(
            CGFloat(value.x) * factor,
            CGFloat(value.y) * factor,
            CGFloat(value.z) * factor
        )
    }
}
