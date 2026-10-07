import SwiftUI
import TSDKit

@main
struct MacDesignApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { DesignDocument() }) { config in
            EditorView(document: config.document, fileURL: config.fileURL)
        }
        .commands {
            EditorCommands()
        }
    }
}
