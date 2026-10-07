import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import TSDKit

struct EditorView: View {
    @ObservedObject var document: DesignDocument
    let fileURL: URL?
    @StateObject private var state: EditorState
    @Environment(\.undoManager) private var undoManager

    init(document: DesignDocument, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
        _state = StateObject(wrappedValue: EditorState(document: document))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CanvasView(state: state, doc: document.doc)
                .ignoresSafeArea()
            ToolPalette(state: state)
                .padding(12)
                .zIndex(1)
            VStack {
                Spacer()
                HStack {
                    if let msg = state.statusMessage {
                        Text(msg).font(.caption.monospaced()).padding(8).glassEffect(.regular, in: .capsule).padding(12)
                    }
                    Spacer()
                    ZoomReadout(state: state)
                        .padding(12)
                }
            }
            .allowsHitTesting(false)
            if document.doc.isReadOnly {
                VStack {
                    ReadOnlyBanner(reason: document.doc.fallbackReason)
                    Spacer()
                }
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
            }
        }
        .inspector(isPresented: $state.showInspector) {
            InspectorView(state: state, document: document)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar { EditorToolbar(state: state, document: document, fileURL: fileURL) }
        .focusedSceneValue(\.editorState, state)
        .onAppear { state.undoManager = undoManager }
        .frame(minWidth: 900, minHeight: 560)
    }
}

// MARK: - Toolbar

struct EditorToolbar: ToolbarContent {
    @ObservedObject var state: EditorState
    @ObservedObject var document: DesignDocument
    let fileURL: URL?

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(ExportKind.allCases) { kind in
                    Button("Export as \(kind.title)…") { ExportPanel.run(kind, document: document.doc, suggestedName: baseName) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the drawing for other software")

            Button {
                state.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
        }
    }

    private var baseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Drawing"
    }
}

// MARK: - Export

enum ExportKind: String, CaseIterable, Identifiable {
    case svg, dxf, pdf, png
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var utType: UTType {
        switch self {
        case .svg: return .svg
        case .dxf: return UTType(filenameExtension: "dxf") ?? .data
        case .pdf: return .pdf
        case .png: return .png
        }
    }
}

enum ExportPanel {
    @MainActor
    static func run(_ kind: ExportKind, document: TSDDocument, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Export as \(kind.title)"
        panel.nameFieldStringValue = "\(suggestedName).\(kind.rawValue)"
        panel.allowedContentTypes = [kind.utType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            switch kind {
            case .svg: data = try Exporter.data(for: document, format: .svg)
            case .dxf: data = try Exporter.data(for: document, format: .dxf)
            case .pdf: data = Renderer.pdfData(for: document)
            case .png:
                guard let image = Renderer.image(for: document, dotsPerMM: 8) else { throw TSDError.cannotWrite("Could not render the page.") }
                let rep = NSBitmapImageRep(cgImage: image)
                guard let png = rep.representation(using: .png, properties: [:]) else { throw TSDError.cannotWrite("PNG encoding failed.") }
                data = png
            }
            try data.write(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

// MARK: - Overlays

struct ZoomReadout: View {
    @ObservedObject var state: EditorState

    var body: some View {
        HStack(spacing: 2) {
            Button { state.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus") }
            Button { state.needsZoomToFit = true } label: {
                Text("\(Int((state.zoom * 25.4 / 72 * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 48)
            }
            .help("Zoom to fit")
            Button { state.zoom(by: 1.25) } label: { Image(systemName: "plus") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}

struct ReadOnlyBanner: View {
    let reason: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 2) {
                Text("Opened in view-only mode. Export works; saving as .3vs doesn't.")
                if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

// MARK: - Focused value for menu commands

struct EditorStateKey: FocusedValueKey {
    typealias Value = EditorState
}

extension FocusedValues {
    var editorState: EditorState? {
        get { self[EditorStateKey.self] }
        set { self[EditorStateKey.self] = newValue }
    }
}

struct EditorCommands: Commands {
    @FocusedValue(\.editorState) private var state

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Select All") { state?.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(state == nil)
            Button("Deselect All") { state?.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(state == nil)
            Button("Duplicate") { state?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(state?.selection.isEmpty ?? true)
        }
        CommandMenu("Object") {
            Button("Group") { state?.groupSelection() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled((state?.selection.count ?? 0) < 2)
            Button("Ungroup") { state?.ungroupSelection() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(state?.selection.isEmpty ?? true)
            Divider()
            Button("Bring to Front") { state?.arrange(.front) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Bring Forward") { state?.arrange(.forward) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Send Backward") { state?.arrange(.backward) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Send to Back") { state?.arrange(.back) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Divider()
            ForEach(Tool.allCases) { tool in
                Button("\(tool.title) Tool") { state?.tool = tool }
                    .keyboardShortcut(KeyEquivalent(tool.shortcut), modifiers: [.command, .control])
            }
        }
        CommandMenu("View") {
            Button("Zoom In") { state?.zoom(by: 1.25) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { state?.zoom(by: 1 / 1.25) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Zoom to Fit") { state?.needsZoomToFit = true }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Show Inspector") { state?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
