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
    }
}

final class PickingSceneView: SCNView {
    var onSelect: ((String?) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(
            point,
            options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue]
        )

        let selected = hits.lazy.compactMap { result -> String? in
            var node: SCNNode? = result.node
            while let current = node {
                if let name = current.name, UUID(uuidString: name) != nil { return name }
                node = current.parent
            }
            return nil
        }.first

        onSelect?(selected)
        super.mouseDown(with: event)
    }
}
