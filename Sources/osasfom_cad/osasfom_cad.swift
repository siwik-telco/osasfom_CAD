import osasfom_cadCore
import SwiftUI

@main
struct osasfom_cad: App {
    @StateObject private var document = CADDocument()

    var body: some Scene {
        WindowGroup {
            MainView(document: document)
                .frame(minWidth: 1_280, minHeight: 820)
        }
    }
}
