import SwiftUI
import Combine
import UniformTypeIdentifiers
import TSDKit

extension UTType {
    /// TechSoft 2D Design V3 drawing (.3vs / .tsd). Declared in Info.plist as an imported type.
    static let tsdDrawing = UTType(importedAs: "com.techsoft.2ddesign.drawing")
}

/// The document shown in each window. Holds the parsed file and takes part in the
/// standard save / revert / undo machinery through DocumentGroup.
final class DesignDocument: ReferenceFileDocument {
    typealias Snapshot = TSDDocument

    static var readableContentTypes: [UTType] { [.tsdDrawing] }
    static var writableContentTypes: [UTType] { [.tsdDrawing] }

    @Published var doc: TSDDocument

    init() {
        doc = TSDDocument.blank()
    }

    nonisolated init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        doc = try TSDParser.parse(data: data)
    }

    func snapshot(contentType: UTType) throws -> TSDDocument {
        doc
    }

    nonisolated func fileWrapper(snapshot: TSDDocument, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try TSDWriter.data(for: snapshot))
    }

    /// Replaces the model and registers the inverse with the undo manager.
    func replace(with new: TSDDocument, actionName: String, undoManager: UndoManager?) {
        let old = doc
        guard old != new else { return }
        doc = new
        undoManager?.registerUndo(withTarget: self) { target in
            target.replace(with: old, actionName: actionName, undoManager: undoManager)
        }
        undoManager?.setActionName(actionName)
    }
}
