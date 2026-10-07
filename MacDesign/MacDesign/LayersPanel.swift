import SwiftUI
import Combine
import TSDKit

/// Illustrator-style layers list: layers top to bottom, each showing its objects in
/// stacking order (topmost first). Drag objects to reorder within a layer; use the
/// arrows to reorder layers.
struct LayersPanel: View {
    @ObservedObject var state: EditorState
    @ObservedObject var document: DesignDocument

    private var layersTopFirst: [Layer] { document.doc.layers.reversed() }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.selection) {
                ForEach(layersTopFirst) { layer in
                    Section {
                        ForEach(objects(in: layer)) { object in
                            ObjectRow(object: object, state: state)
                                .tag(object.id)
                                .listRowBackground(state.activeLayer == layer.index ? Color.accentColor.opacity(0.06) : nil)
                        }
                        .onMove { source, destination in
                            state.moveObjects(inLayer: layer.index, from: source, to: destination)
                        }
                    } header: {
                        LayerHeader(layer: layer, state: state, document: document)
                    }
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 24)

            Divider()
            HStack {
                Button { state.addLayer() } label: { Image(systemName: "plus") }
                    .help("New layer")
                Button {
                    if let l = document.doc.layer(withIndex: state.activeLayer) { state.deleteLayer(l) }
                } label: { Image(systemName: "minus") }
                    .help("Delete the active layer")
                    .disabled(document.doc.layers.count < 2)
                Spacer()
                Text(state.selection.isEmpty ? "No selection" : "\(state.selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func objects(in layer: Layer) -> [DesignObject] {
        document.doc.objects.filter { $0.layer == layer.index }.reversed()
    }
}

private struct LayerHeader: View {
    let layer: Layer
    @ObservedObject var state: EditorState
    @ObservedObject var document: DesignDocument
    @State private var editingName = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Button {
                state.updateLayer(layer.id, actionName: layer.isVisible ? "Hide Layer" : "Show Layer") { $0.isVisible.toggle() }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? Color.primary : Color.secondary)
            }
            .help("Show or hide this layer")
            Button {
                state.updateLayer(layer.id, actionName: layer.isLocked ? "Unlock Layer" : "Lock Layer") { $0.isLocked.toggle() }
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .foregroundStyle(layer.isLocked ? Color.primary : Color.secondary)
            }
            .help("Lock or unlock this layer")

            if editingName {
                TextField("Layer name", text: $draft, onCommit: {
                    let name = draft.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { state.updateLayer(layer.id, actionName: "Rename Layer") { $0.name = name } }
                    editingName = false
                })
                .textFieldStyle(.roundedBorder)
                .onExitCommand { editingName = false }
            } else {
                Text(layer.name)
                    .fontWeight(state.activeLayer == layer.index ? .semibold : .regular)
                    .onTapGesture(count: 2) { draft = layer.name; editingName = true }
                    .onTapGesture(count: 1) { state.activeLayer = layer.index }
            }
            Spacer()
            Text("\(document.doc.objects.filter { $0.layer == layer.index }.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button { move(up: true) } label: { Image(systemName: "chevron.up") }
                .disabled(isTop)
                .help("Move layer up")
            Button { move(up: false) } label: { Image(systemName: "chevron.down") }
                .disabled(isBottom)
                .help("Move layer down")
        }
        .buttonStyle(.borderless)
        .textCase(nil)
        .contextMenu {
            Button("Rename…") { draft = layer.name; editingName = true }
            Button("Make Active") { state.activeLayer = layer.index }
            Button("Select All on Layer") {
                state.selection = Set(document.doc.objects.filter { $0.layer == layer.index }.map { $0.id })
            }
            Divider()
            Button("Delete Layer", role: .destructive) { state.deleteLayer(layer) }
                .disabled(document.doc.layers.count < 2)
        }
    }

    private var position: Int { document.doc.layers.firstIndex { $0.id == layer.id } ?? 0 }
    private var isTop: Bool { position == document.doc.layers.count - 1 }
    private var isBottom: Bool { position == 0 }

    private func move(up: Bool) {
        let count = document.doc.layers.count
        let display = count - 1 - position           // index in top-first order
        let target = up ? display - 1 : display + 2  // onMove-style destination
        guard target >= 0, target <= count else { return }
        state.moveLayers(from: IndexSet(integer: display), to: target)
    }
}

private struct ObjectRow: View {
    let object: DesignObject
    @ObservedObject var state: EditorState

    var body: some View {
        HStack(spacing: 6) {
            Button {
                state.mutate(object.isVisible ? "Hide" : "Show") { doc in doc.update(object.id) { $0.isVisible.toggle() } }
            } label: {
                Image(systemName: object.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(object.isVisible ? Color.secondary : Color.secondary.opacity(0.5))
            }
            Button {
                state.mutate(object.isLocked ? "Unlock" : "Lock") { doc in doc.update(object.id) { $0.isLocked.toggle() } }
            } label: {
                Image(systemName: object.isLocked ? "lock.fill" : "lock.open")
                    .foregroundStyle(object.isLocked ? Color.primary : Color.secondary.opacity(0.5))
            }
            Image(systemName: object.shape.systemImage)
                .frame(width: 16)
                .foregroundStyle(object.style.effectiveStroke.color)
            Text(object.displayName)
                .lineLimit(1)
            Spacer()
            if let fill = object.style.fill.representativeColor {
                Circle().fill(fill.color).frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
            }
        }
        .buttonStyle(.borderless)
        .padding(.leading, 12)
        .contextMenu {
            Button("Bring to Front") { state.selection = [object.id]; state.arrange(.front) }
            Button("Send to Back") { state.selection = [object.id]; state.arrange(.back) }
            Divider()
            Menu("Move to Layer") {
                ForEach(state.doc.layers) { layer in
                    Button(layer.name) { state.selection = [object.id]; state.moveSelection(toLayer: layer.index) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { state.selection = [object.id]; state.deleteSelection() }
        }
    }
}
