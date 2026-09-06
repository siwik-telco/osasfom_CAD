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
        /// Booleans are part of the mesh, so a change to any step has to
        /// invalidate the cached geometry the same way a change to the base
        /// primitive does.
        let booleans: [ResolvedBooleanOperation]
    }

    public static func signature(for body: ResolvedBody) -> ShapeSignature {
        ShapeSignature(shape: body.shape, booleans: body.booleans)
    }

    /// A body's mesh, with its boolean history applied.
    ///
    /// A body without booleans keeps using SceneKit's own parametric
    /// primitives — they are cheaper, and they carry proper texture
    /// coordinates. Only a body that is actually cut pays for a custom mesh.
    public static func makeGeometry(for body: ResolvedBody) -> SCNGeometry {
        guard usesCustomMesh(body) else { return makeGeometry(for: body.shape) }
        return makeMeshGeometry(BodyMesh.localTriangles(for: body))
    }

    /// The intrinsic orientation to apply alongside `makeGeometry(for:)`.
    /// A CSG mesh is generated in the body's own frame with the primitive's
    /// axis already baked in, so it must not be turned again.
    public static func intrinsicRotation(for body: ResolvedBody) -> SCNVector3 {
        usesCustomMesh(body) ? SCNVector3Zero : intrinsicRotation(for: body.shape)
    }

    /// A zero-thickness sheet is a surface, so there is no solid for a
    /// boolean to cut — it keeps its plane, and the resolver warns as much.
    private static func usesCustomMesh(_ body: ResolvedBody) -> Bool {
        !body.booleans.isEmpty && body.shape.degenerateAxis == nil
    }

    /// Flat-shaded geometry from a triangle soup: vertices are emitted
    /// per-face rather than shared, so each facet keeps its own normal and a
    /// cut face reads as a crisp edge instead of a smeared one.
    static func makeMeshGeometry(_ triangles: [STLExporter.Triangle]) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        vertices.reserveCapacity(triangles.count * 3)
        normals.reserveCapacity(triangles.count * 3)

        for triangle in triangles {
            let normal = vector(STLExporter.faceNormal(triangle))
            for corner in [triangle.v0, triangle.v1, triangle.v2] {
                vertices.append(vector(corner))
                normals.append(normal)
            }
        }

        guard !vertices.isEmpty else { return SCNGeometry() }

        let element = SCNGeometryElement(
            indices: Array(UInt32(0)..<UInt32(vertices.count)),
            primitiveType: .triangles
        )
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [element]
        )
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

        case .cylinder(let radius, let begin, let end, _):
            // SCNCylinder is Y-aligned; the node's own rotation orients it.
            return SCNCylinder(radius: CGFloat(radius), height: CGFloat(abs(end - begin)))

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

        case .cylinder(_, _, _, let axis):
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

    /// Geometry for a radiation pattern, coloured by level.
    ///
    /// Vertex colours carry the dB ramp, so one draw call shows the whole
    /// pattern and the shading survives any camera angle — the alternative,
    /// slicing the surface into per-colour submeshes, would break the
    /// surface into visible bands.
    public static func makeFarFieldGeometry(_ mesh: FarFieldMesh, opacity: Double = 0.85) -> SCNGeometry {
        let positions = mesh.vertices.map { vector($0.position) }
        let indices = mesh.indices.map { UInt32($0) }

        // Built from raw float RGBA rather than an [NSColor] convenience
        // initializer, which SceneKit does not offer for a colour source.
        var componentData = [Float]()
        componentData.reserveCapacity(mesh.vertices.count * 4)
        for vertex in mesh.vertices {
            let color = patternColor(level: vertex.level)
            componentData += [
                Float(color.redComponent),
                Float(color.greenComponent),
                Float(color.blueComponent),
                1
            ]
        }
        let stride = MemoryLayout<Float>.size * 4
        let colorSource = SCNGeometrySource(
            data: Data(bytes: componentData, count: componentData.count * MemoryLayout<Float>.size),
            semantic: .color,
            vectorCount: mesh.vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: stride
        )

        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: positions), colorSource],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )

        let material = SCNMaterial()
        // Constant lighting: the surface encodes a measurement, and shading it
        // would make the same level read as two different colours depending on
        // which way the lobe happens to face.
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = NSColor.white
        material.transparency = CGFloat(min(max(opacity, 0), 1))
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    /// The shared ramp from Core, as an `NSColor` for the vertex buffer.
    static func patternColor(level: Double) -> NSColor {
        NSColor(FarFieldColorRamp.color(level: level))
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

    /// A small billboarded text label, e.g. for naming the X/Y/Z axes in the
    /// viewport so a non-technical user can tell them apart at a glance.
    public static func makeLabelNode(text: String, color: NSColor, size: CGFloat = 6) -> SCNNode {
        let textGeometry = SCNText(string: text, extrusionDepth: 0)
        textGeometry.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        textGeometry.flatness = 0.2
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        material.isDoubleSided = true
        textGeometry.materials = [material]

        let node = SCNNode(geometry: textGeometry)
        let (boundsMin, boundsMax) = textGeometry.boundingBox
        let scale = size / Swift.max(CGFloat(boundsMax.x - boundsMin.x), 1)
        node.scale = SCNVector3(scale, scale, scale)
        // Centre the glyph on its node origin instead of SceneKit's default
        // bottom-left, so the label sits squarely at the tip of an axis.
        node.pivot = SCNMatrix4MakeTranslation(
            (boundsMin.x + boundsMax.x) / 2,
            (boundsMin.y + boundsMax.y) / 2,
            (boundsMin.z + boundsMax.z) / 2
        )
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    /// A solid cylindrical tube from `start` to `end` — used where a plain
    /// `.line` primitive (always hairline-thin regardless of camera distance)
    /// isn't visible enough, e.g. a lumped port's feed gap.
    public static func makeTubeNode(from start: Vec3, to end: Vec3, radius: Double, color: NSColor) -> SCNNode {
        let delta = end - start
        let length = (delta.x * delta.x + delta.y * delta.y + delta.z * delta.z).squareRoot()
        guard length > 0 else { return SCNNode() }

        let cylinder = SCNCylinder(radius: CGFloat(max(radius, 1e-6)), height: CGFloat(length))
        cylinder.materials = [makeLineMaterial(color: color)]

        let node = SCNNode(geometry: cylinder)
        node.position = vector(Vec3(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2, z: (start.z + end.z) / 2))
        node.rotation = rotationFromYAxis(to: Vec3(x: delta.x / length, y: delta.y / length, z: delta.z / length))
        return node
    }

    /// A small solid sphere at a point — used to mark a lumped port's begin
    /// (red) and end (blue) terminals distinctly.
    public static func makeMarkerNode(at point: Vec3, radius: Double, color: NSColor) -> SCNNode {
        let sphere = SCNSphere(radius: CGFloat(max(radius, 1e-6)))
        sphere.materials = [makeLineMaterial(color: color)]
        let node = SCNNode(geometry: sphere)
        node.position = vector(point)
        return node
    }

    /// Axis-angle rotation taking SceneKit's default +Y cylinder axis onto
    /// unit vector `direction`, i.e. `cross((0,1,0), direction)` as the axis
    /// and `acos(dot((0,1,0), direction))` as the angle.
    private static func rotationFromYAxis(to direction: Vec3) -> SCNVector4 {
        let dot = direction.y
        if dot > 1 - 1e-9 { return SCNVector4(0, 1, 0, 0) }
        if dot < -1 + 1e-9 { return SCNVector4(1, 0, 0, Double.pi) }

        let cross = Vec3(x: direction.z, y: 0, z: -direction.x)
        let crossLength = (cross.x * cross.x + cross.y * cross.y + cross.z * cross.z).squareRoot()
        guard crossLength > 0 else { return SCNVector4(0, 1, 0, 0) }
        let angle = acos(max(-1, min(1, dot)))
        return SCNVector4(cross.x / crossLength, cross.y / crossLength, cross.z / crossLength, angle)
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
