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
            ToolPalette(state: state)
                .padding(12)
                .zIndex(1)
            VStack {
                Spacer()
                HStack {
                    if let msg = state.statusMessage {
                        Text(msg).font(.caption.monospaced()).padding(8).glassEffect(.regular, in: .capsule).padding(12)
                            .allowsHitTesting(false)
                    }
                    Spacer()
                    ZoomReadout(state: state)
                        .padding(12)
                }
            }
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
        .sheet(isPresented: $state.explodeRequest) { ExplodeSheet(state: state) }
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

            LockControls()

            ToolbarAlignMenu(state: state)
                .help("Align or distribute the selected objects")

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
        // Hide loses ⌘H so Make Path can have it, as in 2D Design.
        CommandGroup(replacing: .appVisibility) {
            Button("Hide MacDesign") { NSApp.hide(nil) }
                .keyboardShortcut("h", modifiers: [.command, .control])
            Button("Hide Others") { NSApp.hideOtherApplications(nil) }
                .keyboardShortcut("h", modifiers: [.command, .option])
            Button("Show All") { NSApp.unhideAllApplications(nil) }
        }
        // The Find and Spelling submenus claim ⌘E, ⌘G and ⌘J; a drawing app doesn't need them.
        CommandGroup(replacing: .textEditing) {}
        CommandGroup(after: .pasteboard) {
            if let state { EditMenuItems(state: state) }
        }
        CommandMenu("Object") {
            if let state { ObjectMenuItems(state: state) }
        }
        CommandGroup(before: .toolbar) {
            ViewMenuItems(state: state)
        }
    }
}

/// Menu items observe the editor so they enable and disable with the selection.
struct EditMenuItems: View {
    @ObservedObject var state: EditorState

    var body: some View {
        Button("Select All") { state.selectAll() }
            .keyboardShortcut("a", modifiers: .command)
        Button("Deselect All") { state.deselectAll() }
            .keyboardShortcut("a", modifiers: [.command, .shift])
        Button("Duplicate") { state.duplicateSelection() }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(state.selection.isEmpty)
    }
}

struct ObjectMenuItems: View {
    @ObservedObject var state: EditorState

    private var hasGroup: Bool {
        state.selectedObjects.contains { if case .group = $0.shape { return true } else { return false } }
    }

    var body: some View {
        Button("Group") { state.groupSelection() }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(state.selection.count < 2)
        Button("Ungroup") { state.ungroupSelection() }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!hasGroup)
        Divider()
        Button("Make Path") { state.makePath() }
            .keyboardShortcut("h", modifiers: .command)
            .disabled(state.selection.isEmpty)
        Button("Explode…") { state.requestExplode() }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(state.selection.isEmpty)
        Divider()
        Button("Bring to Front") { state.arrange(.front) }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(state.selection.isEmpty)
        Button("Bring Forward") { state.arrange(.forward) }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(state.selection.isEmpty)
        Button("Send Backward") { state.arrange(.backward) }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(state.selection.isEmpty)
        Button("Send to Back") { state.arrange(.back) }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(state.selection.isEmpty)
        Divider()
        AlignMenu(state: state)
        Divider()
        ForEach(Tool.allCases) { tool in
            Button("\(tool.title) Tool") { state.tool = tool }
                .keyboardShortcut(KeyEquivalent(tool.shortcut), modifiers: [.command, .control])
        }
    }
}

/// Zoom and grid, in the standard View menu.
struct ViewMenuItems: View {
    let state: EditorState?
    @AppStorage(GridPrefs.showGridKey) private var showGrid = true
    @AppStorage(GridPrefs.lockModeKey) private var lockMode = LockMode.grid.rawValue
    @AppStorage(GridPrefs.snapToObjectsKey) private var snapToObjects = true
    @AppStorage(GridPrefs.gridSpacingKey) private var gridSpacing = 10.0
    @AppStorage(GridPrefs.majorEveryKey) private var majorEvery = 1
    @AppStorage(GridPrefs.hapticsKey) private var haptics = true

    var body: some View {
        Button("Zoom In") { state?.zoom(by: 1.25) }
            .keyboardShortcut("=", modifiers: .command)
        Button("Zoom Out") { state?.zoom(by: 1 / 1.25) }
            .keyboardShortcut("-", modifiers: .command)
        Button("Zoom to Fit") { state?.needsZoomToFit = true }
            .keyboardShortcut("0", modifiers: .command)
        Divider()
        Toggle("Show Grid", isOn: $showGrid)
            .keyboardShortcut("'", modifiers: .command)
        Picker("Lock", selection: $lockMode) {
            ForEach(LockMode.allCases, id: \.rawValue) { Label($0.title, systemImage: $0.systemImage).tag($0.rawValue) }
        }
        .pickerStyle(.inline)
        Button("Cycle Lock") { lockMode = (LockMode(rawValue: lockMode) ?? .grid).next.rawValue }
            .keyboardShortcut("l", modifiers: .command)
        Toggle("Snap to Objects", isOn: $snapToObjects)
            .keyboardShortcut("'", modifiers: [.command, .shift])
        Menu("Grid Spacing") {
            ForEach(GridPrefs.spacingPresets, id: \.self) { v in
                Toggle(GridPrefs.spacingLabel(v), isOn: Binding(get: { abs(gridSpacing - v) < 1e-9 }, set: { if $0 { gridSpacing = v } }))
            }
            if !GridPrefs.spacingPresets.contains(where: { abs($0 - gridSpacing) < 1e-9 }) {
                Toggle(GridPrefs.spacingLabel(gridSpacing), isOn: .constant(true))
            }
            Divider()
            Button("Other…") { GridPrefs.askForCustomSpacing() }
        }
        Menu("Major Lines") {
            ForEach(GridPrefs.majorPresets, id: \.self) { n in
                Toggle(n == 1 ? "None" : "Every \(n) lines", isOn: Binding(get: { majorEvery == n }, set: { if $0 { majorEvery = n } }))
            }
        }
        Toggle("Haptic Feedback When Snapping", isOn: $haptics)
        Divider()
        Button("Show Inspector") { state?.showInspector.toggle() }
            .keyboardShortcut("i", modifiers: [.command, .option])
        Divider()
    }
}

/// The toolbar's align menu. Observes the editor so it enables as soon as something is selected.
struct ToolbarAlignMenu: View {
    @ObservedObject var state: EditorState

    var body: some View {
        Menu {
            AlignMenuItems(state: state)
        } label: {
            Label("Align", systemImage: "align.horizontal.left")
        }
        .disabled(state.selection.isEmpty)
    }
}

/// Align and distribute items, used in the Object menu.
struct AlignMenu: View {
    let state: EditorState?

    var body: some View {
        Menu("Align") {
            AlignMenuItems(state: state)
        }
        .disabled(state?.selection.isEmpty ?? true)
    }
}

struct AlignMenuItems: View {
    let state: EditorState?

    private var count: Int { state?.selection.count ?? 0 }

    var body: some View {
        Group {
            ForEach([EditorState.AlignEdge.left, .centreX, .right], id: \.self) { edge in
                Button(edge.title, systemImage: edge.systemImage) { state?.align(edge) }
            }
            Divider()
            ForEach([EditorState.AlignEdge.top, .centreY, .bottom], id: \.self) { edge in
                Button(edge.title, systemImage: edge.systemImage) { state?.align(edge) }
            }
            Divider()
            Button("Distribute Horizontally", systemImage: "distribute.horizontal.center") { state?.distribute(horizontally: true) }
                .disabled(count < 3)
            Button("Distribute Vertically", systemImage: "distribute.vertical.center") { state?.distribute(horizontally: false) }
                .disabled(count < 3)
            if count == 1 {
                Divider()
                Text("One object aligns to the page")
            }
        }
    }
}


/// Joined pair in the toolbar: the lock mode (cycles grid, step, none) and object snapping.
struct LockControls: View {
    @AppStorage(GridPrefs.lockModeKey) private var lockMode = LockMode.grid.rawValue
    @AppStorage(GridPrefs.snapToObjectsKey) private var snapToObjects = true

    private var mode: LockMode { LockMode(rawValue: lockMode) ?? .grid }

    var body: some View {
        ControlGroup {
            Button {
                withAnimation(.snappy) { lockMode = mode.next.rawValue }
            } label: {
                Label(mode.title, systemImage: mode.systemImage)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .help("\(mode.title): click to change. Grid lock snaps to the grid, step lock to every millimetre.")

            Toggle(isOn: $snapToObjects) {
                Label("Snap", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .help("Snap to the edges and centres of other objects and the page")
        }
    }
}
