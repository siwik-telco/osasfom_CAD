import AppKit
import SwiftUI
import osasfom_cadCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct osasfom_cad: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var document = CADDocument.makeStarterDocument()

    var body: some Scene {
        WindowGroup {
            MainView(document: document)
                .frame(minWidth: 1_180, minHeight: 780)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .commands { commands }
    }

    @CommandsBuilder
    private var commands: some Commands {
        // Undo is a snapshot stack on the document rather than UndoManager, so
        // the standard menu items are replaced with ones that drive it.
        CommandGroup(replacing: .undoRedo) {
            Button(document.undoActionName.map { "Undo \($0)" } ?? "Undo") {
                document.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!document.canUndo)

            Button(document.redoActionName.map { "Redo \($0)" } ?? "Redo") {
                document.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!document.canRedo)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Open…") { postDocumentCommand(.open) }
                .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Save") { postDocumentCommand(.save) }
                .keyboardShortcut("s", modifiers: .command)

            Button("Save As…") { postDocumentCommand(.saveAs) }
                .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Button("Export Solver Deck…") { postDocumentCommand(.exportSolverDeck) }
                .keyboardShortcut("e", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button("Zoom to Fit") { postDocumentCommand(.zoomToFit) }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
