import osasfom_cadCore
import AppKit
import SceneKit
import SwiftUI

struct MainView: View {
    @ObservedObject var document: CADDocument

    var body: some View {
        NavigationSplitView {
            SidebarView(document: document)
        } content: {
            SceneWorkspaceView(document: document)
        } detail: {
            InspectorView(document: document)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    document.addBody(.box)
                } label: {
                    Label("Box", systemImage: "cube")
                }

                Button {
                    document.addBody(.cylinder)
                } label: {
                    Label("Cylinder", systemImage: "cylinder")
                }

                Button {
                    document.addBody(.sheet)
                } label: {
                    Label("Sheet", systemImage: "square")
                }

                Divider()

                Button {
                    document.duplicateSelectedBody()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(document.selectedBodyIndex == nil)

                Button(role: .destructive) {
                    document.deleteSelectedBody()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(document.selectedBodyIndex == nil)

                Divider()

                Button {
                    exportProject(document: document)
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func exportProject(document: CADDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "osasfom_cad-project.json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try document.serializeProjectData()
            try data.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var document: CADDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 12)

            HStack {
                Button("Box") {
                    document.addBody(.box)
                }
                Button("Cylinder") {
                    document.addBody(.cylinder)
                }
                Button("Sheet") {
                    document.addBody(.sheet)
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

            List(selection: $document.selectedBodyID) {
                ForEach(document.bodies) { body in
                    Label(body.name, systemImage: iconName(for: body.primitive))
                        .tag(Optional(body.id))
                }
            }

            HStack {
                Text("Units: \(document.units)")
                Spacer()
                Text("Bodies: \(document.bodies.count)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 260)
    }

    private func iconName(for primitive: PrimitiveKind) -> String {
        switch primitive {
        case .box:
            return "cube"
        case .cylinder:
            return "cylinder"
        case .sheet:
            return "square"
        }
    }
}

private struct SceneWorkspaceView: View {
    @ObservedObject var document: CADDocument

    var body: some View {
        ZStack(alignment: .topLeading) {
            SceneViewport(document: document)
                .background(Color.black.opacity(0.96))

            VStack(alignment: .leading, spacing: 8) {
                Text("osasfom_cad")
                    .font(.headline)
                Text("Manual CAD workspace for antenna geometry")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Add solids, set dimensions, place them in 3D, assign materials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding()
        }
    }
}

private struct InspectorView: View {
    @ObservedObject var document: CADDocument

    var body: some View {
        Group {
            if let selectedBodyIndex = document.selectedBodyIndex {
                BodyInspector(
                    bodyModel: $document.bodies[selectedBodyIndex],
                    materials: document.materials,
                    deleteAction: { document.deleteSelectedBody() }
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No Selection")
                        .font(.headline)
                    Text("Select a solid from the list or click one in the 3D viewport.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 340)
    }
}

private struct BodyInspector: View {
    @Binding var bodyModel: CADBody
    let materials: [MaterialDefinition]
    let deleteAction: () -> Void

    private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(3))

    var body: some View {
        Form {
            Section("Body") {
                TextField("Name", text: $bodyModel.name)
                Picker("Primitive", selection: $bodyModel.primitive) {
                    ForEach(PrimitiveKind.allCases) { primitive in
                        Text(primitive.displayName).tag(primitive)
                    }
                }
                .onChange(of: bodyModel.primitive) { newValue in
                    bodyModel.parameters.sanitize(for: newValue)
                }
                Toggle("Visible", isOn: $bodyModel.isVisible)
            }

            Section("Dimensions") {
                switch bodyModel.primitive {
                case .box:
                    TextField("Width (X)", value: $bodyModel.parameters.size.x, format: numberFormat)
                    TextField("Height (Y)", value: $bodyModel.parameters.size.y, format: numberFormat)
                    TextField("Depth (Z)", value: $bodyModel.parameters.size.z, format: numberFormat)
                case .cylinder:
                    TextField("Radius", value: $bodyModel.parameters.radius, format: numberFormat)
                    TextField("Height", value: $bodyModel.parameters.height, format: numberFormat)
                case .sheet:
                    TextField("Width (X)", value: $bodyModel.parameters.size.x, format: numberFormat)
                    TextField("Thickness (Y)", value: $bodyModel.parameters.size.y, format: numberFormat)
                    TextField("Depth (Z)", value: $bodyModel.parameters.size.z, format: numberFormat)
                }
            }

            Section("Transform") {
                Text("Position")
                    .font(.subheadline.weight(.semibold))
                TextField("X", value: $bodyModel.transform.position.x, format: numberFormat)
                TextField("Y", value: $bodyModel.transform.position.y, format: numberFormat)
                TextField("Z", value: $bodyModel.transform.position.z, format: numberFormat)

                Divider()

                Text("Rotation [deg]")
                    .font(.subheadline.weight(.semibold))
                TextField("Rx", value: $bodyModel.transform.rotationDegrees.x, format: numberFormat)
                TextField("Ry", value: $bodyModel.transform.rotationDegrees.y, format: numberFormat)
                TextField("Rz", value: $bodyModel.transform.rotationDegrees.z, format: numberFormat)

                Divider()

                Text("Scale")
                    .font(.subheadline.weight(.semibold))
                TextField("Sx", value: $bodyModel.transform.scale.x, format: numberFormat)
                TextField("Sy", value: $bodyModel.transform.scale.y, format: numberFormat)
                TextField("Sz", value: $bodyModel.transform.scale.z, format: numberFormat)
            }

            Section("Material") {
                Picker("Assignment", selection: $bodyModel.materialID) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(materials) { material in
                        Text(material.name).tag(Optional(material.id))
                    }
                }

                if let selectedMaterial = materials.first(where: { $0.id == bodyModel.materialID }) {
                    Text("εr: \(selectedMaterial.epsilonR?.formatted() ?? "-")")
                    Text("σ: \(selectedMaterial.conductivity?.formatted() ?? "-")")
                }
            }

            Section {
                Button(role: .destructive, action: deleteAction) {
                    Label("Delete Body", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 12)
    }
}

private struct SceneViewport: NSViewRepresentable {
    @ObservedObject var document: CADDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> PickingSceneView {
        let view = PickingSceneView()
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        view.selectionHandler = { nodeName in
            context.coordinator.handleSelection(nodeName: nodeName)
        }
        view.scene = SceneBuilder.makeScene(
            bodies: document.bodies,
            materials: document.materials,
            selectedBodyID: document.selectedBodyID
        )
        return view
    }

    func updateNSView(_ nsView: PickingSceneView, context: Context) {
        nsView.selectionHandler = { nodeName in
            context.coordinator.handleSelection(nodeName: nodeName)
        }
        nsView.scene = SceneBuilder.makeScene(
            bodies: document.bodies,
            materials: document.materials,
            selectedBodyID: document.selectedBodyID
        )
    }

    @MainActor
    final class Coordinator {
        private let document: CADDocument

        init(document: CADDocument) {
            self.document = document
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

private final class PickingSceneView: SCNView {
    var selectionHandler: ((String?) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hitResults = hitTest(point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
        let selectedName = hitResults.compactMap { result -> String? in
            var node: SCNNode? = result.node
            while let currentNode = node {
                if let name = currentNode.name, UUID(uuidString: name) != nil {
                    return name
                }
                node = currentNode.parent
            }
            return nil
        }.first

        selectionHandler?(selectedName)
        super.mouseDown(with: event)
    }
}
