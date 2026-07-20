import osasfom_cadCore
import AppKit
import SceneKit
import SwiftUI

struct MainView: View {
    @ObservedObject var document: CADDocument
    @State private var addSheetKind: PrimitiveKind?

    var body: some View {
        HSplitView {
            SidebarView(document: document, openAddSheet: { kind in
                addSheetKind = kind
            })
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 420)

            SceneWorkspaceView(document: document)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

            InspectorView(document: document)
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $addSheetKind) { kind in
            AddBodySheet(document: document, kind: kind)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    addSheetKind = .box
                } label: {
                    Label("Box", systemImage: "cube")
                }

                Button {
                    addSheetKind = .cylinder
                } label: {
                    Label("Cylinder", systemImage: "cylinder")
                }

                Button {
                    addSheetKind = .sheet
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
    let openAddSheet: (PrimitiveKind) -> Void

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Model")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 12)

                HStack {
                    Button("Box") {
                        openAddSheet(.box)
                    }
                    Button("Cylinder") {
                        openAddSheet(.cylinder)
                    }
                    Button("Sheet") {
                        openAddSheet(.sheet)
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

                if let selectedBodyIndex = document.selectedBodyIndex {
                    ModelQuickEditView(bodyModel: $document.bodies[selectedBodyIndex])
                        .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Units: \(document.units)")
                        Spacer()
                        Text("Bodies: \(document.bodies.count)")
                    }

                    Text("Drag split dividers to resize model, variables, and viewport panels.")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VariablesPanelView(document: document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
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

private struct ModelQuickEditView: View {
    @Binding var bodyModel: CADBody

    private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(3))

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Edit")
                .font(.headline)

            TextField("Element name", text: $bodyModel.name)
                .textFieldStyle(.roundedBorder)

            switch bodyModel.primitive {
            case .box:
                quickSizeField(title: "Width", value: $bodyModel.parameters.size.x)
                quickSizeField(title: "Height", value: $bodyModel.parameters.size.y)
                quickSizeField(title: "Depth", value: $bodyModel.parameters.size.z)
            case .cylinder:
                quickSizeField(title: "Radius", value: $bodyModel.parameters.radius)
                quickSizeField(title: "Height", value: $bodyModel.parameters.height)
            case .sheet:
                quickSizeField(title: "Width", value: $bodyModel.parameters.size.x)
                quickSizeField(title: "Thickness", value: $bodyModel.parameters.size.y)
                quickSizeField(title: "Depth", value: $bodyModel.parameters.size.z)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func quickSizeField(title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            TextField(title, value: value, format: numberFormat)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
        }
    }
}

private struct SceneWorkspaceView: View {
    @ObservedObject var document: CADDocument

    var body: some View {
        ZStack(alignment: .topLeading) {
            SceneViewport(document: document)
                .background(Color.black.opacity(0.96))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text("osasfom_cad")
                    .font(.headline)
                Text("Manual CAD workspace for antenna geometry")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Add solids, set dimensions, place them in 3D, assign materials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Resize the side panels by dragging the split dividers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    variableNames: document.variableNames(),
                    applyVariablesAction: { document.applyVariablesToBodies() },
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct BodyInspector: View {
    @Binding var bodyModel: CADBody
    let materials: [MaterialDefinition]
    let variableNames: [String]
    let applyVariablesAction: () -> Void
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

            Section("Variables") {
                DimensionVariableBindingsView(bodyModel: $bodyModel, variableNames: variableNames)
                Text("Linked variables override the corresponding dimensions when their values change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ranges") {
                BodyBoundsEditorView(bodyModel: $bodyModel)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: bodyModel.variableBindings) { _ in
            applyVariablesAction()
        }
    }
}

private struct VariablesPanelView: View {
    @ObservedObject var document: CADDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Variables", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button {
                    document.variables.append(CADVariable(name: "var\(document.variables.count + 1)", value: 10))
                    document.applyVariablesToBodies()
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)

            Text("Edit variables here. Linked bodies update live when values change.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            List {
                ForEach($document.variables) { $variable in
                    VariableRowView(variable: $variable)
                }
                .onDelete { offsets in
                    document.variables.remove(atOffsets: offsets)
                    document.applyVariablesToBodies()
                }
            }
            .listStyle(.inset)

            HStack {
                Text("Variables: \(document.variables.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Panel below model tree")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onChange(of: document.variables) { _ in
            document.applyVariablesToBodies()
        }
    }
}

private struct VariableRowView: View {
    @Binding var variable: CADVariable

    private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(6))

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField("Name", text: $variable.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                TextField("Value", value: $variable.value, format: numberFormat)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                TextField("Description", text: $variable.description)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DimensionVariableBindingsView: View {
    @Binding var bodyModel: CADBody
    let variableNames: [String]

    var body: some View {
        switch bodyModel.primitive {
        case .box:
            VStack(spacing: 10) {
                variablePickerRow(title: "Width variable", selection: binding(for: \.width))
                variablePickerRow(title: "Height variable", selection: binding(for: \.height))
                variablePickerRow(title: "Depth variable", selection: binding(for: \.depth))
            }
        case .cylinder:
            VStack(spacing: 10) {
                variablePickerRow(title: "Radius variable", selection: binding(for: \.radius))
                variablePickerRow(title: "Height variable", selection: binding(for: \.height))
            }
        case .sheet:
            VStack(spacing: 10) {
                variablePickerRow(title: "Width variable", selection: binding(for: \.width))
                variablePickerRow(title: "Thickness variable", selection: binding(for: \.height))
                variablePickerRow(title: "Depth variable", selection: binding(for: \.depth))
            }
        }
    }

    private func variablePickerRow(title: String, selection: Binding<String?>) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Picker(title, selection: selection) {
                Text("None").tag(Optional<String>.none)
                ForEach(variableNames, id: \.self) { variableName in
                    Text(variableName).tag(Optional(variableName))
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private func binding(for keyPath: WritableKeyPath<BodyVariableBindings, String?>) -> Binding<String?> {
        Binding(
            get: { bodyModel.variableBindings[keyPath: keyPath] },
            set: { newValue in
                bodyModel.variableBindings[keyPath: keyPath] = newValue
            }
        )
    }
}

private struct AddBodySheet: View {
    @ObservedObject var document: CADDocument
    let kind: PrimitiveKind

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var bounds: BodyBounds

    init(document: CADDocument, kind: PrimitiveKind) {
        self.document = document
        self.kind = kind

        switch kind {
        case .box:
            _bounds = State(initialValue: .defaultBox)
        case .cylinder:
            _bounds = State(initialValue: .defaultCylinder)
        case .sheet:
            _bounds = State(initialValue: .defaultSheet)
        }
    }

    private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(3))

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add \(kind.displayName)")
                .font(.title2.weight(.semibold))

            Text("Define the spatial extent of the new solid using X/Y/Z min and max values.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Element name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)

            BodyBoundsFields(bounds: $bounds, numberFormat: numberFormat)

            if kind == .cylinder {
                Text("For cylinders, radius is derived from the smaller X/Z span and height from the Y span.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Add") {
                    var sanitizedBounds = bounds
                    sanitizedBounds.sanitize()
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    document.addBody(kind, bounds: sanitizedBounds, name: trimmedName.isEmpty ? nil : trimmedName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct BodyBoundsEditorView: View {
    @Binding var bodyModel: CADBody

    private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(3))

    var body: some View {
        BodyBoundsFields(bounds: boundsBinding, numberFormat: numberFormat)
    }

    private var boundsBinding: Binding<BodyBounds> {
        Binding(
            get: { bodyModel.bounds },
            set: { newBounds in
                bodyModel.applyBounds(newBounds)
            }
        )
    }
}

private struct BodyBoundsFields: View {
    @Binding var bounds: BodyBounds
    let numberFormat: FloatingPointFormatStyle<Double>

    var body: some View {
        VStack(spacing: 10) {
            boundsRow(axis: "X", minValue: binding(for: \.xMin), maxValue: binding(for: \.xMax))
            boundsRow(axis: "Y", minValue: binding(for: \.yMin), maxValue: binding(for: \.yMax))
            boundsRow(axis: "Z", minValue: binding(for: \.zMin), maxValue: binding(for: \.zMax))
        }
    }

    private func boundsRow(axis: String, minValue: Binding<Double>, maxValue: Binding<Double>) -> some View {
        HStack {
            Text(axis)
                .frame(width: 20, alignment: .leading)
                .foregroundStyle(.secondary)

            TextField("\(axis) min", value: minValue, format: numberFormat)
                .textFieldStyle(.roundedBorder)

            TextField("\(axis) max", value: maxValue, format: numberFormat)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func binding(for keyPath: WritableKeyPath<BodyBounds, Double>) -> Binding<Double> {
        Binding(
            get: { bounds[keyPath: keyPath] },
            set: { newValue in
                var updatedBounds = bounds
                updatedBounds[keyPath: keyPath] = newValue
                updatedBounds.sanitize()
                bounds = updatedBounds
            }
        )
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
