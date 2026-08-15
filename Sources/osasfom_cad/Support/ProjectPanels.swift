import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Menu commands are posted as notifications so the `Commands` builder does not
/// need a reference to the view's state.
enum DocumentCommand {
    case open
    case save
    case saveAs
    case exportSolverDeck
    case zoomToFit
}

extension Notification.Name {
    static let cadDocumentCommand = Notification.Name("osasfom_cad.documentCommand")
}

func postDocumentCommand(_ command: DocumentCommand) {
    NotificationCenter.default.post(name: .cadDocumentCommand, object: command)
}

enum ProjectPanels {
    static let projectExtension = "osasfomcad"

    private static var projectContentType: UTType {
        UTType(filenameExtension: projectExtension) ?? .json
    }

    static func chooseProjectToOpen() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [projectContentType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Open an osasfom_cad project."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func chooseProjectSaveLocation(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [projectContentType]
        panel.nameFieldStringValue = "\(suggestedName).\(projectExtension)"
        panel.canCreateDirectories = true
        panel.message = "Save the editable project. Expressions are preserved."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func chooseSolverExportLocation(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(suggestedName)-fdtd.json"
        panel.canCreateDirectories = true
        panel.message = "Export the resolved FDTD setup. All lengths are in metres."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
