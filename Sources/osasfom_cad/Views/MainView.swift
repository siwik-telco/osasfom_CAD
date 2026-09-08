import SwiftUI
import osasfom_cadCore
import osasfom_cadRender
import osasfom_cadSolver

struct MainView: View {
    @ObservedObject var document: CADDocument
    @StateObject private var simulationRunner = SimulationRunner()

    @State private var inspectorTab: InspectorTab = .body
    @State private var viewOptions = SceneController.ViewOptions()
    @State private var farFieldFrequencyIndex = 0
    @State private var farFieldQuantity: FarFieldQuantity = .directivity
    @State private var frameRequestToken = 0
    @State private var isShowingDiagnostics = false
    @State private var alert: AlertContent?
    /// Non-nil while a "New" (or similar discard-current-document) action is
    /// waiting on the unsaved-changes confirmation dialog.
    @State private var pendingDiscardAction: (() -> Void)?

    enum InspectorTab: String, CaseIterable, Identifiable {
        case body = "Body"
        case simulation = "Simulation"
        case materials = "Materials"
        case run = "Run"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .body: return "cube"
            case .simulation: return "waveform.path"
            case .materials: return "paintpalette"
            case .run: return "play.circle"
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
        .confirmationDialog(
            "Save changes to “\(document.displayName)” first?",
            isPresented: Binding(
                get: { pendingDiscardAction != nil },
                set: { if !$0 { pendingDiscardAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save") { saveThenRunPendingDiscardAction() }
            Button("Don't Save", role: .destructive) { runPendingDiscardAction() }
            Button("Cancel", role: .cancel) { pendingDiscardAction = nil }
        } message: {
            Text("Your changes will be lost if you don't save them.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .cadDocumentCommand)) { notification in
            handle(notification)
        }
    }

    // MARK: - Workspace

    private var workspace: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                SceneViewport(
                    document: document,
                    farField: farFieldOverlayMesh,
                    options: viewOptions,
                    frameRequestToken: frameRequestToken
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    Spacer()
                    if let request = document.facePickRequest {
                        facePickBanner(request)
                    }
                    Spacer()
                }
                .padding(.top, 12)

                HStack(alignment: .top) {
                    // Bottom-left, clear of the option checkboxes on the right.
                    VStack {
                        Spacer()
                        farFieldLegendOverlay
                    }
                    Spacer()
                    VStack {
                        viewOptionsOverlay
                        Spacer()
                    }
                }
                .padding(12)
            }
            .onExitCommand {
                if document.facePickRequest != nil { document.facePickRequest = nil }
            }

            DiagnosticsBar(
                document: document,
                isExpanded: $isShowingDiagnostics
            )
        }
    }

    private func facePickBanner(_ request: FacePickRequest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.point.up.left.fill")
            Text("Click a body's face to set the \(request.terminal == .begin ? "Begin" : "End") terminal")
                .font(.callout)
            Button("Cancel") {
                document.facePickRequest = nil
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .shadow(radius: 2)
    }

    /// The pattern drawn over the model: the selected frequency's, scaled to
    /// the model so it reads against the geometry rather than dwarfing it or
    /// vanishing inside it. A pattern is a shape, not a size — its true
    /// radius is meaningless — so the scale is presentational on purpose.
    private var farFieldOverlayMesh: FarFieldMesh? {
        guard viewOptions.showFarField else { return nil }
        let patterns = simulationRunner.farFieldPatterns
        guard !patterns.isEmpty else { return nil }
        let pattern = patterns.indices.contains(farFieldFrequencyIndex)
            ? patterns[farFieldFrequencyIndex]
            : patterns[0]

        let extent = document.resolved.modelBounds?.size.largestComponent ?? 0
        let radius = extent > 0 ? extent * 0.75 : 10
        return pattern.mesh(quantity: farFieldQuantity, radius: radius)
    }

    private var viewOptionsOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Grid", isOn: $viewOptions.showGrid)
            Toggle("Domain", isOn: $viewOptions.showDomain)
            Toggle("Ports", isOn: $viewOptions.showPorts)
            if !simulationRunner.farFieldPatterns.isEmpty {
                Toggle("Far field", isOn: $viewOptions.showFarField)
                if viewOptions.showFarField {
                    farFieldOpacityControl
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(.caption)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Fades the pattern back so the antenna inside it stays visible. The
    /// slider reaches zero, which hides the surface outright — the same
    /// result as the checkbox, but reachable without letting go of the
    /// control you are already dragging.
    private var farFieldOpacityControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.secondary)
            Slider(value: $viewOptions.farFieldOpacity, in: 0...1)
                .frame(width: 92)
            Text("\(Int(viewOptions.farFieldOpacity * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.leading, 2)
        .help("Pattern opacity. Drag to zero to hide it.")
    }

    /// The colour scale for the pattern currently drawn.
    @ViewBuilder
    private var farFieldLegendOverlay: some View {
        if viewOptions.showFarField,
           viewOptions.farFieldOpacity > 0.001,
           let mesh = farFieldOverlayMesh,
           !mesh.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(farFieldQuantity.displayName)
                    .font(.caption.bold())
                FarFieldLegendView(mesh: mesh, unitLabel: farFieldQuantity.unitLabel)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
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
                if document.canCombineSelectedBodies {
                    CombineSelectionView(document: document)
                } else if let selectedBodyID = document.selectedBodyID,
                          document.state.body(id: selectedBodyID) != nil {
                    BodyInspectorView(document: document, bodyID: selectedBodyID)
                } else {
                    emptySelection
                }
            case .simulation:
                SimulationInspectorView(document: document)
            case .materials:
                MaterialsInspectorView(document: document)
            case .run:
                SimulationRunnerView(
                    document: document,
                    runner: simulationRunner,
                    farFieldFrequencyIndex: $farFieldFrequencyIndex,
                    farFieldQuantity: $farFieldQuantity
                )
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

            Menu {
                if let target = document.combineTargetBody {
                    Text("Keeps “\(target.name)”")
                }
                ForEach(BooleanKind.allCases) { kind in
                    Button {
                        document.combineSelectedBodies(kind)
                    } label: {
                        Label(kind.displayName, systemImage: kind.symbolName)
                    }
                }
            } label: {
                Label("Combine", systemImage: "square.on.square.dashed")
            }
            .disabled(!document.canCombineSelectedBodies)
            .help("Combine the selected bodies. Select two or more; the first one picked is kept.")

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

            Button {
                exportSTL()
            } label: {
                Label("Export STL", systemImage: "cube.transparent")
            }
            .help("Write visible geometry as STL, for comparison in another EM tool")
        }
    }

    // MARK: - Commands

    private func handle(_ notification: Notification) {
        guard let command = notification.object as? DocumentCommand else { return }
        switch command {
        case .new: newProject()
        case .open: openProject()
        case .save: saveProject(forcingPrompt: false)
        case .saveAs: saveProject(forcingPrompt: true)
        case .exportSolverDeck: exportSolverDeck()
        case .exportSTL: exportSTL()
        case .zoomToFit: frameRequestToken += 1
        // Owned by RootView, which is what decides whether the window shows
        // the welcome screen or the editor.
        case .showWelcome: break
        }
    }

    private func newProject() {
        confirmDiscardingUnsavedChanges {
            document.resetToNewDocument()
            frameRequestToken += 1
        }
    }

    private func openProject() {
        confirmDiscardingUnsavedChanges {
            guard let url = ProjectPanels.chooseProjectToOpen() else { return }
            do {
                try document.load(from: url)
                frameRequestToken += 1
            } catch {
                alert = AlertContent(title: "Could not open project", message: message(for: error))
            }
        }
    }

    /// Runs `action` immediately if the document has no unsaved changes;
    /// otherwise defers it behind the Save / Don't Save / Cancel dialog, so
    /// "New" and "Open" can never silently discard work in progress.
    private func confirmDiscardingUnsavedChanges(then action: @escaping () -> Void) {
        guard document.hasUnsavedChanges else {
            action()
            return
        }
        pendingDiscardAction = action
    }

    private func runPendingDiscardAction() {
        pendingDiscardAction?()
        pendingDiscardAction = nil
    }

    private func saveThenRunPendingDiscardAction() {
        do {
            if try document.save() {
                runPendingDiscardAction()
                return
            }
            guard let url = ProjectPanels.chooseProjectSaveLocation(
                suggestedName: document.displayName
            ) else {
                // Cancelled the save panel — cancel the pending action too,
                // rather than proceeding to discard unsaved work anyway.
                pendingDiscardAction = nil
                return
            }
            try document.save(to: url)
            runPendingDiscardAction()
        } catch {
            alert = AlertContent(title: "Could not save project", message: message(for: error))
            pendingDiscardAction = nil
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

    private func exportSTL() {
        let data = document.stlExportData()
        guard let url = ProjectPanels.chooseSTLExportLocation(
            suggestedName: document.displayName,
            unitSymbol: document.state.lengthUnit.symbol
        ) else { return }
        do {
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
