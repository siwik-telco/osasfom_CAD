import SwiftUI
import osasfom_cadCore

/// What the single application window is currently showing.
///
/// The welcome screen and the editor share one window rather than being two
/// scenes: on macOS 13 there is no way to stop a `WindowGroup` opening at
/// launch, so a separate launcher window would always flash the empty editor
/// behind it.
struct RootView: View {
    @ObservedObject var document: CADDocument
    @StateObject private var recentProjects = RecentProjects()

    @State private var isShowingWelcome = true
    @State private var pendingWelcomeAction: (() -> Void)?
    @State private var openFailure: String?

    var body: some View {
        Group {
            if isShowingWelcome {
                WelcomeView(
                    recentProjects: recentProjects,
                    newProject: { guarded(startNewProject) },
                    openProject: { guarded(browseForProject) },
                    openRecent: { url in guarded { open(url) } }
                )
            } else {
                MainView(document: document)
                    .frame(minWidth: 1_180, minHeight: 780)
            }
        }
        // Recording here rather than at each call site means every route to a
        // file — open, save, save-as, and a recent-list click — lands in the
        // list, and none can be forgotten later.
        .onChange(of: document.fileURL) { url in
            if let url { recentProjects.record(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cadDocumentCommand)) { notification in
            guard case .showWelcome? = notification.object as? DocumentCommand else { return }
            isShowingWelcome = true
        }
        .confirmationDialog(
            "Your project has unsaved changes.",
            isPresented: Binding(
                get: { pendingWelcomeAction != nil },
                set: { if !$0 { pendingWelcomeAction = nil } }
            )
        ) {
            Button("Save…") { saveThenRunPendingAction() }
            Button("Don't Save", role: .destructive) {
                let action = pendingWelcomeAction
                pendingWelcomeAction = nil
                action?()
            }
            Button("Cancel", role: .cancel) { pendingWelcomeAction = nil }
        } message: {
            Text("Opening another project will discard them.")
        }
        .alert(
            "Could not open project",
            isPresented: Binding(
                get: { openFailure != nil },
                set: { if !$0 { openFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { openFailure = nil }
        } message: {
            Text(openFailure ?? "")
        }
    }

    // MARK: - Actions

    /// At launch the document is always pristine, so this is a no-op then.
    /// It matters when the welcome screen is reopened mid-session.
    private func guarded(_ action: @escaping () -> Void) {
        guard document.hasUnsavedChanges else {
            action()
            return
        }
        pendingWelcomeAction = action
    }

    private func saveThenRunPendingAction() {
        let action = pendingWelcomeAction
        pendingWelcomeAction = nil
        do {
            if try document.save() {
                action?()
                return
            }
            guard
                let url = ProjectPanels.chooseProjectSaveLocation(suggestedName: document.displayName)
            else { return }
            try document.save(to: url)
            action?()
        } catch {
            openFailure = error.localizedDescription
        }
    }

    private func startNewProject() {
        document.resetToNewDocument()
        isShowingWelcome = false
    }

    private func browseForProject() {
        guard let url = ProjectPanels.chooseProjectToOpen() else { return }
        open(url)
    }

    private func open(_ url: URL) {
        do {
            try document.load(from: url)
            isShowingWelcome = false
        } catch {
            // A project that has been moved or deleted is the common case, so
            // the row stays in the list and the reason is shown rather than
            // the click doing nothing.
            openFailure = error.localizedDescription
        }
    }
}
