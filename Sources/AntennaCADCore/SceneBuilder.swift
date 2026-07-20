import AppKit
import Foundation
import SceneKit

public enum SceneBuilder {
    public static func makeScene(
        bodies: [CADBody],
        materials: [MaterialDefinition],
        selectedBodyID: UUID?
    ) -> SCNScene {
        let scene = SCNScene()

        scene.rootNode.addChildNode(makeCameraNode())
        scene.rootNode.addChildNode(makeAmbientLightNode())
        scene.rootNode.addChildNode(makeDirectionalLightNode())
        scene.rootNode.addChildNode(makeAxesNode(length: 120))
        scene.rootNode.addChildNode(makeGridNode(size: 200, step: 10))

        for body in bodies where body.isVisible {
            let node = makeNode(for: body, materials: materials, isSelected: body.id == selectedBodyID)
            scene.rootNode.addChildNode(node)
        }

        return scene
    }

    private static func makeNode(
        for body: CADBody,
        materials: [MaterialDefinition],
        isSelected: Bool
    ) -> SCNNode {
        let geometry: SCNGeometry

        switch body.primitive {
        case .box:
            geometry = SCNBox(
                width: body.parameters.size.x,
                height: body.parameters.size.y,
                length: body.parameters.size.z,
                chamferRadius: 0
            )
        case .cylinder:
            geometry = SCNCylinder(
                radius: body.parameters.radius,
                height: body.parameters.height
            )
        case .sheet:
            geometry = SCNBox(
                width: body.parameters.size.x,
                height: body.parameters.size.y,
                length: body.parameters.size.z,
                chamferRadius: 0
            )
        }

        let material = SCNMaterial()
        let color = materials.first(where: { $0.id == body.materialID })?.color ?? .neutralGray
        material.diffuse.contents = NSColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
        material.specular.contents = NSColor.white.withAlphaComponent(0.15)
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.25
        material.roughness.contents = 0.45
        material.emission.contents = isSelected
            ? NSColor.systemYellow.withAlphaComponent(0.35)
            : NSColor.clear
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = body.id.uuidString
        node.position = SCNVector3(
            body.transform.position.x,
            body.transform.position.y,
            body.transform.position.z
        )
        node.eulerAngles = SCNVector3(
            degreesToRadians(body.transform.rotationDegrees.x),
            degreesToRadians(body.transform.rotationDegrees.y),
            degreesToRadians(body.transform.rotationDegrees.z)
        )
        node.scale = SCNVector3(
            body.transform.scale.x,
            body.transform.scale.y,
            body.transform.scale.z
        )

        if isSelected {
            node.addChildNode(makeSelectionBounds(for: geometry))
        }

        return node
    }

    private static func makeSelectionBounds(for geometry: SCNGeometry) -> SCNNode {
        let (minBox, maxBox) = geometry.boundingBox
        let width = CGFloat(maxBox.x - minBox.x)
        let height = CGFloat(maxBox.y - minBox.y)
        let length = CGFloat(maxBox.z - minBox.z)
        let bounds = SCNBox(
            width: max(width, 0.01),
            height: max(height, 0.01),
            length: max(length, 0.01),
            chamferRadius: 0
        )
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.clear
        material.emission.contents = NSColor.systemYellow
        material.fillMode = .lines
        bounds.materials = [material]
        return SCNNode(geometry: bounds)
    }

    private static func makeCameraNode() -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zNear = 0.1
        camera.zFar = 5_000

        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(150, 120, 180)
        node.look(at: SCNVector3(0, 0, 0))
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
        light.intensity = 1_200
        light.castsShadow = true
        let node = SCNNode()
        node.light = light
        node.eulerAngles = SCNVector3(-0.8, 0.9, 0)
        return node
    }

    private static func makeAxesNode(length: CGFloat) -> SCNNode {
        let node = SCNNode()
        node.addChildNode(lineNode(
            from: SCNVector3Zero,
            to: SCNVector3(Float(length), 0, 0),
            color: .systemRed,
            name: nil
        ))
        node.addChildNode(lineNode(
            from: SCNVector3Zero,
            to: SCNVector3(0, Float(length), 0),
            color: .systemGreen,
            name: nil
        ))
        node.addChildNode(lineNode(
            from: SCNVector3Zero,
            to: SCNVector3(0, 0, Float(length)),
            color: .systemBlue,
            name: nil
        ))
        return node
    }

    private static func makeGridNode(size: Int, step: Int) -> SCNNode {
        let node = SCNNode()
        for offset in stride(from: -size, through: size, by: step) {
            let xLine = lineNode(
                from: SCNVector3(Float(offset), 0, Float(-size)),
                to: SCNVector3(Float(offset), 0, Float(size)),
                color: NSColor.gridColor.withAlphaComponent(0.45),
                name: nil
            )
            let zLine = lineNode(
                from: SCNVector3(Float(-size), 0, Float(offset)),
                to: SCNVector3(Float(size), 0, Float(offset)),
                color: NSColor.gridColor.withAlphaComponent(0.45),
                name: nil
            )
            node.addChildNode(xLine)
            node.addChildNode(zLine)
        }
        return node
    }

    private static func lineNode(
        from: SCNVector3,
        to: SCNVector3,
        color: NSColor,
        name: String?
    ) -> SCNNode {
        let source = SCNGeometrySource(vertices: [from, to])
        let element = SCNGeometryElement(indices: [UInt32(0), UInt32(1)], primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = name
        return node
    }

    private static func degreesToRadians(_ degrees: Double) -> Float {
        Float(degrees * .pi / 180)
    }
}
