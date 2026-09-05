import AppKit
import SceneKit
import SwiftUI
import osasfom_cadCore
import osasfom_cadRender

/// Bridges the long-lived `SceneController` into SwiftUI.
///
/// `updateNSView` reconciles the existing scene instead of replacing it, so the
/// camera keeps whatever orbit the user set. The controller lives in the
/// coordinator, which SwiftUI keeps alive across view updates.
struct SceneViewport: NSViewRepresentable {
    @ObservedObject var document: CADDocument
    let options: SceneController.ViewOptions
    /// Incremented by the toolbar to request a camera reframe. Because framing is
    /// explicit, an edit never moves the camera.
    let frameRequestToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> PickingSceneView {
        let view = PickingSceneView()
        view.scene = context.coordinator.controller.scene
        view.pointOfView = context.coordinator.controller.cameraNode
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = SceneStyle.background
        // Rendering on demand: the old view ran a continuous 60 fps loop while
        // rebuilding the whole scene every update.
        view.rendersContinuously = false
        view.onSelect = { [weak coordinator = context.coordinator] nodeName in
            coordinator?.handleSelection(nodeName: nodeName)
        }
        view.onFacePick = { [weak coordinator = context.coordinator] nodeName, worldPoint in
            coordinator?.handleFacePick(nodeName: nodeName, worldPoint: worldPoint)
        }
        view.isFacePicking = document.facePickRequest != nil

        context.coordinator.sync(options: options)
        context.coordinator.controller.frame(bounds: document.resolved.modelBounds)
        context.coordinator.lastFrameToken = frameRequestToken
        return view
    }

    func updateNSView(_ nsView: PickingSceneView, context: Context) {
        context.coordinator.document = document
        context.coordinator.sync(options: options)

        if frameRequestToken != context.coordinator.lastFrameToken {
            context.coordinator.lastFrameToken = frameRequestToken
            context.coordinator.controller.frame(bounds: document.resolved.modelBounds)
            // Reattach: the built-in camera controller may have swapped in its
            // own point of view while orbiting.
            nsView.pointOfView = context.coordinator.controller.cameraNode
        }

        nsView.onSelect = { [weak coordinator = context.coordinator] nodeName in
            coordinator?.handleSelection(nodeName: nodeName)
        }
        nsView.onFacePick = { [weak coordinator = context.coordinator] nodeName, worldPoint in
            coordinator?.handleFacePick(nodeName: nodeName, worldPoint: worldPoint)
        }
        nsView.isFacePicking = document.facePickRequest != nil
    }

    @MainActor
    final class Coordinator {
        let controller = SceneController()
        var document: CADDocument
        var lastFrameToken = -1

        init(document: CADDocument) {
            self.document = document
        }

        func sync(options: SceneController.ViewOptions) {
            controller.sync(
                resolved: document.resolved,
                materials: document.state.materials,
                selectedBodyID: document.selectedBodyID,
                options: options
            )
        }

        func handleSelection(nodeName: String?) {
            guard let nodeName, let id = UUID(uuidString: nodeName) else {
                document.selectedBodyID = nil
                return
            }
            document.selectedBodyID = id
        }

        /// Resolves a viewport click into the nearest face of the clicked
        /// body and writes that face's center into the armed port terminal.
        func handleFacePick(nodeName: String, worldPoint: Vec3) {
            guard
                let request = document.facePickRequest,
                let bodyID = UUID(uuidString: nodeName),
                let body = document.resolved.body(id: bodyID)
            else { return }

            let facePoint = Self.nearestFaceCenter(of: body.axisAlignedBounds, to: worldPoint)
            document.updatePort(request.portID, actionName: "Set Port Terminal From Face") { port in
                switch request.terminal {
                case .begin: port.begin = Vector3Expression(facePoint)
                case .end: port.end = Vector3Expression(facePoint)
                }
            }
            document.facePickRequest = nil
        }

        /// The face of `bounds` closest to `point`, as its center — a click
        /// lands on the body's surface, so exactly one axis/side pair should
        /// be (near) an exact match; ties fall back to the first found.
        private static func nearestFaceCenter(of bounds: BodyBounds, to point: Vec3) -> Vec3 {
            var bestAxis: Axis = .x
            var bestIsUpper = false
            var bestDistance = Double.greatestFiniteMagnitude

            for axis in Axis.allCases {
                let distanceToLower = abs(point[axis] - bounds.lower(on: axis))
                let distanceToUpper = abs(point[axis] - bounds.upper(on: axis))
                if distanceToLower < bestDistance {
                    bestDistance = distanceToLower
                    bestAxis = axis
                    bestIsUpper = false
                }
                if distanceToUpper < bestDistance {
                    bestDistance = distanceToUpper
                    bestAxis = axis
                    bestIsUpper = true
                }
            }

            var facePoint = bounds.center
            facePoint[bestAxis] = bestIsUpper ? bounds.upper(on: bestAxis) : bounds.lower(on: bestAxis)
            return facePoint
        }
    }
}

final class PickingSceneView: SCNView {
    var onSelect: ((String?) -> Void)?
    /// Fires instead of `onSelect` while `isFacePicking` is true: (body id
    /// string, world-space point clicked on that body's surface).
    var onFacePick: ((String, Vec3) -> Void)?
    var isFacePicking = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(
            point,
            options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue]
        )

        var foundID: String?
        var worldPoint: SCNVector3?
        for result in hits {
            var node: SCNNode? = result.node
            while let current = node {
                if let name = current.name, UUID(uuidString: name) != nil {
                    foundID = name
                    worldPoint = result.worldCoordinates
                    break
                }
                node = current.parent
            }
            if foundID != nil { break }
        }

        if isFacePicking {
            // Stay armed on an empty-space click rather than silently
            // deselecting — the user is mid-pick, not browsing.
            if let foundID, let worldPoint {
                onFacePick?(foundID, Vec3(x: Double(worldPoint.x), y: Double(worldPoint.y), z: Double(worldPoint.z)))
            }
        } else {
            onSelect?(foundID)
        }
        super.mouseDown(with: event)
    }
}
