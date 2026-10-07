import SwiftUI
import TSDKit

@main
struct MacDesignApp: App {
    init() {
        GridPrefs.register()
        FilletPrefs.register()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { DesignDocument() }) { config in
            EditorView(document: config.document, fileURL: config.fileURL)
        }
        .commands {
            EditorCommands()
        }
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
