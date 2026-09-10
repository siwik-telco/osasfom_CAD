import AppKit
import SwiftUI
import UniformTypeIdentifiers
import osasfom_cadCore

/// Menu commands are posted as notifications so the `Commands` builder does not
/// need a reference to the view's state.
enum DocumentCommand {
    case new
    case open
    case save
    case saveAs
    case exportSolverDeck
    case exportSTL
    case importSTL
    case zoomToFit
    case showWelcome
    case exportResults
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

    /// `fileExtension` comes from the chosen results format, so the panel
    /// offers the right type rather than a generic one.
    static func chooseResultsExportLocation(suggestedName: String, fileExtension: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.message = "Export the return loss. Frequencies are in hertz."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Picks an STL to import, together with the unit its numbers are in.
    ///
    /// The unit is asked for up front rather than fixed afterwards because STL
    /// stores none, and getting it wrong is the failure mode: a part authored
    /// in metres dropped into a millimetre project arrives 1000x too small,
    /// which looks like a broken importer rather than a unit mismatch. The
    /// project's own unit is the default, since that is right whenever the
    /// file came from this program.
    static func chooseSTLToImport(projectUnit: LengthUnit) -> (url: URL, unit: LengthUnit)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stl") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Import a triangle mesh as a body."

        let units = LengthUnit.allCases
        let popup = NSPopUpButton(frame: NSRect(x: 96, y: 4, width: 190, height: 25), pullsDown: false)
        popup.addItems(withTitles: units.map(\.displayName))
        popup.selectItem(at: units.firstIndex(of: projectUnit) ?? 0)

        let label = NSTextField(labelWithString: "File units:")
        label.frame = NSRect(x: 8, y: 8, width: 84, height: 18)
        label.alignment = .right

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 34))
        accessory.addSubview(label)
        accessory.addSubview(popup)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let unit = units.indices.contains(popup.indexOfSelectedItem)
            ? units[popup.indexOfSelectedItem]
            : projectUnit
        return (url, unit)
    }

    static func chooseSTLExportLocation(suggestedName: String, unitSymbol: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stl") ?? .data]
        panel.nameFieldStringValue = "\(suggestedName).stl"
        panel.canCreateDirectories = true
        panel.message = "Export visible geometry as binary STL, in \(unitSymbol). STL carries no unit metadata — tell the importing tool (e.g. CST) which unit to use."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
