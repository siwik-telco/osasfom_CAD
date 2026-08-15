import SwiftUI
import osasfom_cadCore
import osasfom_cadRender

struct MainView: View {
    @ObservedObject var document: CADDocument

    @State private var inspectorTab: InspectorTab = .body
    @State private var viewOptions = SceneController.ViewOptions()
    @State private var frameRequestToken = 0
    @State private var isShowingDiagnostics = false
    @State private var alert: AlertContent?

    enum InspectorTab: String, CaseIterable, Identifiable {
        case body = "Body"
        case simulation = "Simulation"
        case materials = "Materials"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .body: return "cube"
            case .simulation: return "waveform.path"
            case .materials: return "paintpalette"
            }
        }
    }

    var body: some View {
        HSplitView {
            ModelSidebarView(document: document)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 460)

            workspace
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

            inspector
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { toolbarContent }
        .alert(item: $alert) { content in
            Alert(
                title: Text(content.title),
                message: Text(content.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .cadDocumentCommand)) { notification in
            handle(notification)
        }
    }

    // MARK: - Workspace

    private var workspace: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                SceneViewport(
                    document: document,
                    options: viewOptions,
                    frameRequestToken: frameRequestToken
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                viewOptionsOverlay
                    .padding(12)
            }

            DiagnosticsBar(
                document: document,
                isExpanded: $isShowingDiagnostics
            )
        }
    }

    private var viewOptionsOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Grid", isOn: $viewOptions.showGrid)
            Toggle("Domain", isOn: $viewOptions.showDomain)
            Toggle("Ports", isOn: $viewOptions.showPorts)
        }
        .toggleStyle(.checkbox)
        .font(.caption)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbolName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch inspectorTab {
            case .body:
                if let selectedBodyID = document.selectedBodyID,
                   document.state.body(id: selectedBodyID) != nil {
                    BodyInspectorView(document: document, bodyID: selectedBodyID)
                } else {
                    emptySelection
                }
            case .simulation:
                SimulationInspectorView(document: document)
            case .materials:
                MaterialsInspectorView(document: document)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptySelection: some View {
        VStack(spacing: 10) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("No Selection")
                .font(.headline)
            Text("Pick a body from the list or click one in the viewport.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            ForEach(PrimitiveKind.allCases) { kind in
                Button {
                    document.addBody(kind)
                } label: {
                    Label(kind.displayName, systemImage: kind.symbolName)
                }
                .help("Add a \(kind.displayName.lowercased())")
            }

            Divider()

            Button {
                document.duplicateSelectedBody()
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .disabled(document.selectedBodyID == nil)

            Button(role: .destructive) {
                document.deleteSelectedBody()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(document.selectedBodyID == nil)

            Divider()

            Button {
                frameRequestToken += 1
            } label: {
                Label("Zoom to Fit", systemImage: "viewfinder")
            }
            .help("Frame the model. Editing never moves the camera on its own.")

            Divider()

            Button {
                exportSolverDeck()
            } label: {
                Label("Export Solver Deck", systemImage: "square.and.arrow.up")
            }
            .help("Write the resolved, all-SI FDTD setup")
        }
    }

    // MARK: - Commands

    private func handle(_ notification: Notification) {
        guard let command = notification.object as? DocumentCommand else { return }
        switch command {
        case .open: openProject()
        case .save: saveProject(forcingPrompt: false)
        case .saveAs: saveProject(forcingPrompt: true)
        case .exportSolverDeck: exportSolverDeck()
        case .zoomToFit: frameRequestToken += 1
        }
    }

    private func openProject() {
        guard let url = ProjectPanels.chooseProjectToOpen() else { return }
        do {
            try document.load(from: url)
            frameRequestToken += 1
        } catch {
            alert = AlertContent(title: "Could not open project", message: message(for: error))
        }
    }

    private func saveProject(forcingPrompt: Bool) {
        do {
            if !forcingPrompt, try document.save() { return }
            guard let url = ProjectPanels.chooseProjectSaveLocation(
                suggestedName: document.displayName
            ) else { return }
            try document.save(to: url)
        } catch {
            alert = AlertContent(title: "Could not save project", message: message(for: error))
        }
    }

    private func exportSolverDeck() {
        do {
            // Produce the data first: the export refuses while the model has
            // errors, so we should not ask for a filename we cannot fill.
            let data = try document.solverExportData()
            guard let url = ProjectPanels.chooseSolverExportLocation(
                suggestedName: document.displayName
            ) else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            alert = AlertContent(title: "Could not export", message: message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct AlertContent: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Bottom status strip summarising validation, expandable into a full list.
private struct DiagnosticsBar: View {
    @ObservedObject var document: CADDocument
    @Binding var isExpanded: Bool

    private var diagnostics: [Diagnostic] {
        document.resolved.diagnostics.sortedForDisplay()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)

                    if document.resolved.errorCount > 0 {
                        Label("\(document.resolved.errorCount) errors", systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                    if document.resolved.warningCount > 0 {
                        Label("\(document.resolved.warningCount) warnings", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if diagnostics.isEmpty {
                        Label("Model is valid", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Spacer()

                    if let domain = document.resolved.simulation.domain {
                        Text(domainSummary(domain))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded && !diagnostics.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(diagnostics) { diagnostic in
                            DiagnosticRow(diagnostic: diagnostic)
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let bodyID = diagnostic.subject.bodyID {
                                        document.selectedBodyID = bodyID
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 150)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func domainSummary(_ domain: BodyBounds) -> String {
        let unit = document.state.lengthUnit.symbol
        let size = domain.size
        let extent = "\(Expression.literalSource(size.x)) × \(Expression.literalSource(size.y)) × \(Expression.literalSource(size.z)) \(unit)"
        guard let cells = document.resolved.simulation.mesh.estimatedCellCount(domain: domain) else {
            return "Domain \(extent)"
        }
        return "Domain \(extent)  ·  ~\(formatted(cells)) cells"
    }

    private func formatted(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return "\(count / 1_000_000)M"
        case 1_000...: return "\(count / 1_000)k"
        default: return "\(count)"
        }
    }
}
