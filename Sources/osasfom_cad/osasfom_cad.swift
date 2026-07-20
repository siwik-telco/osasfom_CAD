import osasfom_cadCore
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct osasfom_cad: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var document = CADDocument()

    var body: some Scene {
        WindowGroup {
            MainView(document: document)
                .frame(minWidth: 1_280, minHeight: 820)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
    }
}
