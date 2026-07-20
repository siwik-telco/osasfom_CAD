import AntennaCADCore
import SwiftUI

@main
struct AntennaCADApp: App {
    @StateObject private var document = CADDocument()

    var body: some Scene {
        WindowGroup {
            MainView(document: document)
                .frame(minWidth: 1_280, minHeight: 820)
        }
    }
}
