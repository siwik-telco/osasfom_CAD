import AppKit
import SceneKit
import osasfom_cadCore

/// Owns one long-lived `SCNScene` and reconciles it against the resolved model.
///
/// The previous implementation rebuilt the whole scene — camera, lights, grid
/// and all — inside `updateNSView`. Assigning `SCNView.scene` resets
/// `pointOfView`, so every keystroke in the inspector threw away the user's
/// orbit. Here the camera, lights and grid are created once and never replaced;
/// only body nodes are added, updated or removed, and a body's `SCNGeometry` is
/// rebuilt only when its shape signature actually changes.
@MainActor
public final class SceneController {
    public let scene: SCNScene
    public let cameraNode: SCNNode

    private let bodiesRoot = SCNNode()
    private let overlayRoot = SCNNode()
    private let gridRoot = SCNNode()

    private struct BodyEntry {
        var node: SCNNode
        var geometryNode: SCNNode
        var selectionNode: SCNNode?
        var shapeSignature: SceneGeometryFactory.ShapeSignature
        var appearance: Appearance
        var placement: Placement
    }

    /// Everything that affects the material, so it is only rebuilt when needed.
    private struct Appearance: Equatable {
        var color: RGBAColor
        var isSelected: Bool
        var isDoubleSided: Bool
    }

    private struct Placement: Equatable {
        var position: Vec3
        var rotationDegrees: Vec3
        var scale: Vec3
    }

    private var entries: [UUID: BodyEntry] = [:]
    private var gridConfiguration: GridConfiguration?
    private var domainNode: SCNNode?
    private var domainBounds: BodyBounds?
    private var portNodes: [UUID: SCNNode] = [:]
    private var portSignatures: [UUID: BodyBounds] = [:]

    private struct GridConfiguration: Equatable {
        var extent: Double
        var step: Double
    }

    public init() {
        scene = SCNScene()
        cameraNode = Self.makeCameraNode()

        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(Self.makeAmbientLightNode())
        scene.rootNode.addChildNode(Self.makeDirectionalLightNode())
        scene.rootNode.addChildNode(Self.makeAxesNode(length: 60))
        scene.rootNode.addChildNode(gridRoot)
        scene.rootNode.addChildNode(bodiesRoot)
        scene.rootNode.addChildNode(overlayRoot)

        configureGrid(extent: 100, step: 10)
    }

    // MARK: - Reconciliation

    public struct ViewOptions: Equatable, Sendable {
        public var showGrid: Bool
        public var showDomain: Bool
        public var showPorts: Bool

        public init(showGrid: Bool = true, showDomain: Bool = true, showPorts: Bool = true) {
            self.showGrid = showGrid
            self.showDomain = showDomain
            self.showPorts = showPorts
        }
    }

    public func sync(
        resolved: ResolvedModel,
        materials: [MaterialDefinition],
        selectedBodyID: UUID?,
        options: ViewOptions
    ) {
        let materialsByID = Dictionary(
            materials.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var liveIDs: Set<UUID> = []

        for body in resolved.bodies where body.isVisible {
            liveIDs.insert(body.id)
            let material = materialsByID[body.materialID] ?? MaterialLibrary.vacuum
            update(body: body, material: material, isSelected: body.id == selectedBodyID)
        }

        for (id, entry) in entries where !liveIDs.contains(id) {
            entry.node.removeFromParentNode()
            entries.removeValue(forKey: id)
        }

        gridRoot.isHidden = !options.showGrid
        syncGrid(for: resolved)
        syncDomain(resolved.simulation.domain, isVisible: options.showDomain)
        syncPorts(resolved.simulation.ports, isVisible: options.showPorts)
    }

    private func update(body: ResolvedBody, material: MaterialDefinition, isSelected: Bool) {
        let signature = SceneGeometryFactory.signature(for: body.shape)
        let isZeroThicknessSheet = body.shape.degenerateAxis != nil
        let appearance = Appearance(
            color: material.color,
            isSelected: isSelected,
            isDoubleSided: isZeroThicknessSheet || material.color.alpha < 1
        )
        let placement = Placement(
            position: body.position,
            rotationDegrees: body.rotationDegrees,
            scale: body.scale
        )

        guard var entry = entries[body.id] else {
            entries[body.id] = makeEntry(
                for: body,
                signature: signature,
                appearance: appearance,
                placement: placement
            )
            return
        }

        // Rebuilding an SCNGeometry is the expensive part, so only do it when
        // the shape genuinely changed.
        if entry.shapeSignature != signature {
            entry.geometryNode.geometry = SceneGeometryFactory.makeGeometry(for: body.shape)
            entry.geometryNode.eulerAngles = SceneGeometryFactory.intrinsicRotation(for: body.shape)
            entry.shapeSignature = signature
            entry.appearance = Appearance(color: .neutralGray, isSelected: false, isDoubleSided: false)
        }

        if entry.appearance != appearance {
            entry.geometryNode.geometry?.materials = [
                SceneGeometryFactory.makeMaterial(
                    color: appearance.color,
                    isSelected: appearance.isSelected,
                    isDoubleSided: appearance.isDoubleSided
                )
            ]
            entry.appearance = appearance
        }

        if entry.placement != placement {
            applyPlacement(placement, to: entry.node)
            entry.placement = placement
        }

        entry.node.name = body.id.uuidString

        // Selection outline: present only while selected, and sized from the
        // resolved local extents so it hugs the body without z-fighting.
        if isSelected {
            let outlineSize = body.shape.localSize
            if let existing = entry.selectionNode {
                existing.removeFromParentNode()
            }
            let outline = SceneGeometryFactory.makeWireBox(
                size: outlineSize,
                color: SceneStyle.selection,
                lineWidthScale: 1.0
            )
            outline.renderingOrder = 10
            entry.node.addChildNode(outline)
            entry.selectionNode = outline
        } else if let existing = entry.selectionNode {
            existing.removeFromParentNode()
            entry.selectionNode = nil
        }

        entries[body.id] = entry
    }

    private func makeEntry(
        for body: ResolvedBody,
        signature: SceneGeometryFactory.ShapeSignature,
        appearance: Appearance,
        placement: Placement
    ) -> BodyEntry {
        // Two nodes: the outer one carries the user's transform, the inner one
        // the primitive's intrinsic orientation (a cylinder's axis, a plane's
        // normal). Keeping them apart means the user's rotation composes
        // correctly with any primitive.
        let node = SCNNode()
        node.name = body.id.uuidString
        applyPlacement(placement, to: node)

        let geometryNode = SCNNode(geometry: SceneGeometryFactory.makeGeometry(for: body.shape))
        geometryNode.eulerAngles = SceneGeometryFactory.intrinsicRotation(for: body.shape)
        geometryNode.geometry?.materials = [
            SceneGeometryFactory.makeMaterial(
                color: appearance.color,
                isSelected: appearance.isSelected,
                isDoubleSided: appearance.isDoubleSided
            )
        ]
        node.addChildNode(geometryNode)
        bodiesRoot.addChildNode(node)

        var entry = BodyEntry(
            node: node,
            geometryNode: geometryNode,
            selectionNode: nil,
            shapeSignature: signature,
            appearance: appearance,
            placement: placement
        )

        if appearance.isSelected {
            let outline = SceneGeometryFactory.makeWireBox(
                size: body.shape.localSize,
                color: SceneStyle.selection
            )
            outline.renderingOrder = 10
            node.addChildNode(outline)
            entry.selectionNode = outline
        }
        return entry
    }

    private func applyPlacement(_ placement: Placement, to node: SCNNode) {
        node.position = SceneGeometryFactory.vector(placement.position)
        node.eulerAngles = SceneGeometryFactory.degreesToRadians(placement.rotationDegrees)
        node.scale = SceneGeometryFactory.vector(placement.scale)
    }

    // MARK: - Overlays

    private func syncGrid(for resolved: ResolvedModel) {
        let reference = resolved.simulation.domain ?? resolved.modelBounds
        let span = reference.map { max($0.size.x, $0.size.z) } ?? 100
        let extent = max(50, (span * 0.75).rounded(.up))
        let step = max(1, pow(10, (log10(extent / 10)).rounded(.down)))
        let configuration = GridConfiguration(extent: extent, step: step)
        guard configuration != gridConfiguration else { return }
        configureGrid(extent: extent, step: step)
    }

    private func configureGrid(extent: Double, step: Double) {
        gridRoot.childNodes.forEach { $0.removeFromParentNode() }
        gridConfiguration = GridConfiguration(extent: extent, step: step)

        var minorVertices: [SCNVector3] = []
        var majorVertices: [SCNVector3] = []

        var offset = -extent
        while offset <= extent + step / 2 {
            let isMajor = abs(offset.truncatingRemainder(dividingBy: step * 5)) < step / 2
            let pair = [
                SCNVector3(CGFloat(offset), 0, CGFloat(-extent)),
                SCNVector3(CGFloat(offset), 0, CGFloat(extent)),
                SCNVector3(CGFloat(-extent), 0, CGFloat(offset)),
                SCNVector3(CGFloat(extent), 0, CGFloat(offset))
            ]
            if isMajor {
                majorVertices.append(contentsOf: pair)
            } else {
                minorVertices.append(contentsOf: pair)
            }
            offset += step
        }

        if let node = Self.makeLineSetNode(vertices: minorVertices, color: SceneStyle.grid) {
            gridRoot.addChildNode(node)
        }
        if let node = Self.makeLineSetNode(vertices: majorVertices, color: SceneStyle.gridMajor) {
            gridRoot.addChildNode(node)
        }
    }

    private func syncDomain(_ bounds: BodyBounds?, isVisible: Bool) {
        guard isVisible, let bounds else {
            domainNode?.removeFromParentNode()
            domainNode = nil
            domainBounds = nil
            return
        }
        guard bounds != domainBounds || domainNode == nil else { return }

        domainNode?.removeFromParentNode()
        let node = SceneGeometryFactory.makeWireBox(size: bounds.size, color: SceneStyle.domain)
        node.position = SceneGeometryFactory.vector(bounds.center)
        node.opacity = 0.6
        overlayRoot.addChildNode(node)
        domainNode = node
        domainBounds = bounds
    }

    private func syncPorts(_ ports: [ResolvedPort], isVisible: Bool) {
        guard isVisible else {
            portNodes.values.forEach { $0.removeFromParentNode() }
            portNodes.removeAll()
            portSignatures.removeAll()
            return
        }

        var liveIDs: Set<UUID> = []
        for port in ports {
            liveIDs.insert(port.id)
            if portSignatures[port.id] == port.bounds, portNodes[port.id] != nil { continue }

            portNodes[port.id]?.removeFromParentNode()

            let container = SCNNode()
            container.position = SceneGeometryFactory.vector(port.bounds.center)

            // A port is often a degenerate box (a gap with zero cross-section),
            // so draw its extent as a wire box plus an explicit direction arrow.
            let outline = SceneGeometryFactory.makeWireBox(
                size: port.bounds.size,
                color: SceneStyle.port
            )
            container.addChildNode(outline)

            let half = port.bounds.span(on: port.direction) / 2
            let sign: Double = port.isReversed ? -1 : 1
            let tip = port.direction.unitVector * (half * sign)
            container.addChildNode(
                SceneGeometryFactory.makeLineNode(from: tip * -1, to: tip, color: SceneStyle.port)
            )

            overlayRoot.addChildNode(container)
            portNodes[port.id] = container
            portSignatures[port.id] = port.bounds
        }

        for (id, node) in portNodes where !liveIDs.contains(id) {
            node.removeFromParentNode()
            portNodes.removeValue(forKey: id)
            portSignatures.removeValue(forKey: id)
        }
    }

    // MARK: - Camera

    /// Frames the given box. Called explicitly, never as a side effect of an
    /// edit — the whole point is that editing leaves the camera alone.
    public func frame(bounds: BodyBounds?) {
        let target = bounds ?? BodyBounds(center: .zero, size: Vec3(repeating: 100))
        let size = target.size
        let radius = max(max(size.x, size.y), size.z) / 2
        let distance = max(radius * 3.2, 25)
        let center = target.center

        let direction = Vec3(x: 0.62, y: 0.52, z: 0.78)
        let length = (direction.x * direction.x + direction.y * direction.y + direction.z * direction.z).squareRoot()
        let offset = direction * (distance / length)

        cameraNode.position = SceneGeometryFactory.vector(center + offset)
        cameraNode.look(at: SceneGeometryFactory.vector(center))
        cameraNode.camera?.zFar = Double(max(5_000, distance * 20))
    }

    private static func makeCameraNode() -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zNear = 0.05
        camera.zFar = 20_000
        camera.wantsHDR = false

        let node = SCNNode()
        node.name = "camera"
        node.camera = camera
        node.position = SCNVector3(120, 95, 145)
        node.look(at: SCNVector3Zero)
        return node
    }

    private static func makeAmbientLightNode() -> SCNNode {
        let light = SCNLight()
        light.type = .ambient
        light.intensity = 450
        let node = SCNNode()
        node.light = light
        return node
    }

    private static func makeDirectionalLightNode() -> SCNNode {
        let light = SCNLight()
        light.type = .directional
        light.intensity = 1_100
        light.castsShadow = false
        let node = SCNNode()
        node.light = light
        node.eulerAngles = SCNVector3(-0.8, 0.9, 0)
        return node
    }

    private static func makeAxesNode(length: Double) -> SCNNode {
        let node = SCNNode()
        node.name = "axes"
        node.addChildNode(
            SceneGeometryFactory.makeLineNode(
                from: .zero,
                to: Vec3(x: length, y: 0, z: 0),
                color: SceneStyle.axisX
            )
        )
        node.addChildNode(
            SceneGeometryFactory.makeLineNode(
                from: .zero,
                to: Vec3(x: 0, y: length, z: 0),
                color: SceneStyle.axisY
            )
        )
        node.addChildNode(
            SceneGeometryFactory.makeLineNode(
                from: .zero,
                to: Vec3(x: 0, y: 0, z: length),
                color: SceneStyle.axisZ
            )
        )
        return node
    }

    /// One geometry for all grid lines rather than one node per line — the old
    /// code created 80+ nodes for a single grid.
    private static func makeLineSetNode(vertices: [SCNVector3], color: NSColor) -> SCNNode? {
        guard !vertices.isEmpty else { return nil }
        let indices = (0..<vertices.count).map { UInt32($0) }
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [SceneGeometryFactory.makeLineMaterial(color: color)]
        let node = SCNNode(geometry: geometry)
        node.renderingOrder = -10
        return node
    }
}
