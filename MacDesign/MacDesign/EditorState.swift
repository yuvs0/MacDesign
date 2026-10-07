import SwiftUI
import Combine
import AppKit
import TSDKit

enum Tool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, line, arc, pen, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arc: return "Arc"
        case .pen: return "Pen"
        case .text: return "Text"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "arrow.up.left"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arc: return "arrow.counterclockwise"
        case .pen: return "pencil.and.outline"
        case .text: return "textformat"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .rectangle: return "r"
        case .ellipse: return "e"
        case .line: return "l"
        case .arc: return "a"
        case .pen: return "p"
        case .text: return "t"
        }
    }

    var help: String { "\(title) (\(shortcut.uppercased()))" }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case properties = "Properties"
    case layers = "Layers"
    var id: String { rawValue }
}

/// Per-window editing state: tool, selection, view transform, and the single entry
/// point for document mutations (which also handles undo).
@MainActor
final class EditorState: ObservableObject {
    let document: DesignDocument
    weak var undoManager: UndoManager?

    @Published var tool: Tool = .select
    @Published var selection: Set<UUID> = []
    /// Screen points per millimetre.
    @Published var zoom: CGFloat = 2
    /// Screen position of the page's bottom-left corner, in canvas view coordinates (y up).
    @Published var origin: CGPoint = .zero
    @Published var needsZoomToFit = true
    /// Once the user zooms or pans, window resizes stop re-fitting the page.
    var hasUserAdjustedView = false
    /// Current canvas size, kept up to date by the canvas view.
    var viewSize = CGSize(width: 800, height: 600)
    @Published var showInspector = true
    @Published var inspectorTab: InspectorTab = .properties
    @Published var activeLayer: Int = 1
    /// Style applied to new shapes.
    @Published var newShapeStyle = Style(strokeColor: .black)
    @Published var newTextFace = "Arial"
    @Published var newTextSize = 5.0
    /// Set when the text tool creates text so the inspector can focus its field.
    @Published var focusTextRequest = 0
    @Published var statusMessage: String?

    init(document: DesignDocument) {
        self.document = document
        activeLayer = document.doc.layers.first?.index ?? 1
    }

    var doc: TSDDocument { document.doc }

    // MARK: Mutations

    func mutate(_ actionName: String, _ body: (inout TSDDocument) -> Void) {
        var new = document.doc
        body(&new)
        document.replace(with: new, actionName: actionName, undoManager: undoManager)
        selection = selection.filter { new.object(with: $0) != nil }
    }

    // MARK: Selection helpers

    var selectedObjects: [DesignObject] {
        doc.objects.filter { selection.contains($0.id) }
    }

    var selectionBounds: TSDRect? {
        var r: TSDRect?
        for o in selectedObjects {
            guard let b = objectBounds(o) else { continue }
            r = r.map { $0.union(b) } ?? b
        }
        return r
    }

    func objectBounds(_ o: DesignObject) -> TSDRect? {
        switch o.shape {
        case .text(let t): return Renderer.textBounds(t)
        case .group(let kids):
            var r: TSDRect?
            for k in kids { if let b = objectBounds(k) { r = r.map { $0.union(b) } ?? b } }
            return r
        default: return Geometry.bounds(of: o)
        }
    }

    func isEditable(_ o: DesignObject) -> Bool {
        guard o.isVisible, !o.isLocked, let layer = doc.layer(withIndex: o.layer) else { return false }
        return layer.isVisible && !layer.isLocked
    }

    func selectAll() {
        selection = Set(doc.objects.filter { isEditable($0) }.map { $0.id })
    }

    func deselectAll() { selection = [] }

    // MARK: Object operations

    func add(_ object: DesignObject, select: Bool = true) {
        var o = object
        o.layer = activeLayer
        o.fileID = 0
        mutate("Add \(object.shape.kindName)") { $0.objects.append(o) }
        if select { selection = [o.id] }
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        mutate("Delete") { $0.remove(ids: ids) }
        selection = []
    }

    func duplicateSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        var newIDs: Set<UUID> = []
        mutate("Duplicate") { doc in
            var copies: [DesignObject] = []
            for o in doc.objects where ids.contains(o.id) {
                var c = Geometry.transform(o, by: .translation(5, -5))
                c.id = UUID()
                c.fileID = 0
                c.name = o.name.map { "\($0) copy" }
                copies.append(c)
                newIDs.insert(c.id)
            }
            doc.objects.append(contentsOf: copies)
        }
        selection = newIDs
    }

    func transformSelection(_ m: Affine, actionName: String = "Move") {
        let ids = selection
        guard !ids.isEmpty else { return }
        mutate(actionName) { doc in
            for i in doc.objects.indices where ids.contains(doc.objects[i].id) {
                doc.objects[i] = Geometry.transform(doc.objects[i], by: m)
            }
        }
    }

    func nudge(dx: Double, dy: Double) {
        transformSelection(.translation(dx, dy), actionName: "Nudge")
    }

    func updateSelected(_ actionName: String, _ body: (inout DesignObject) -> Void) {
        let ids = selection
        guard !ids.isEmpty else { return }
        mutate(actionName) { doc in
            for i in doc.objects.indices where ids.contains(doc.objects[i].id) { body(&doc.objects[i]) }
        }
    }

    func setStroke(_ color: RGB?) {
        if selection.isEmpty { newShapeStyle.strokeColor = color; return }
        updateSelected("Change Stroke") { o in
            o.style.strokeColor = color
            if case .group(var kids) = o.shape {
                for i in kids.indices { kids[i].style.strokeColor = color }
                o.shape = .group(kids)
            }
        }
    }

    func setFill(_ color: RGB?) {
        if selection.isEmpty { newShapeStyle.fillColor = color; return }
        updateSelected("Change Fill") { o in
            o.style.fillColor = color
            if case .group(var kids) = o.shape {
                for i in kids.indices { kids[i].style.fillColor = color }
                o.shape = .group(kids)
            }
        }
    }

    func setStrokeWidth(_ w: Double) {
        if selection.isEmpty { newShapeStyle.strokeWidth = w; return }
        updateSelected("Change Stroke Width") { $0.style.strokeWidth = max(0, w) }
    }

    func setLineType(_ t: LineType) {
        if selection.isEmpty { newShapeStyle.lineType = t; return }
        updateSelected("Change Line") { $0.style.lineType = t }
    }

    func moveSelection(toLayer index: Int) {
        updateSelected("Move to Layer") { $0.layer = index }
    }

    // MARK: Arrange

    enum ArrangeOp { case front, forward, backward, back }

    func arrange(_ op: ArrangeOp) {
        let ids = selection
        guard !ids.isEmpty else { return }
        mutate("Arrange") { doc in
            let selected = doc.objects.filter { ids.contains($0.id) }
            let rest = doc.objects.filter { !ids.contains($0.id) }
            switch op {
            case .front:
                doc.objects = rest + selected
            case .back:
                doc.objects = selected + rest
            case .forward:
                // Move each selected object one slot up, from the top down.
                var objs = doc.objects
                for i in stride(from: objs.count - 2, through: 0, by: -1) where ids.contains(objs[i].id) && !ids.contains(objs[i + 1].id) {
                    objs.swapAt(i, i + 1)
                }
                doc.objects = objs
            case .backward:
                var objs = doc.objects
                for i in 1..<max(1, objs.count) where ids.contains(objs[i].id) && !ids.contains(objs[i - 1].id) {
                    objs.swapAt(i, i - 1)
                }
                doc.objects = objs
            }
        }
    }

    func groupSelection() {
        let ids = selection
        guard ids.count >= 2 else { return }
        var groupID = UUID()
        mutate("Group") { doc in
            let members = doc.objects.filter { ids.contains($0.id) }
            guard let firstIndex = doc.objects.firstIndex(where: { ids.contains($0.id) }) else { return }
            doc.objects.removeAll { ids.contains($0.id) }
            let g = DesignObject(layer: members.first?.layer ?? 1, shape: .group(members))
            groupID = g.id
            doc.objects.insert(g, at: min(firstIndex, doc.objects.count))
        }
        selection = [groupID]
    }

    func ungroupSelection() {
        let ids = selection
        var newIDs: Set<UUID> = []
        mutate("Ungroup") { doc in
            var result: [DesignObject] = []
            for o in doc.objects {
                if ids.contains(o.id), case .group(let kids) = o.shape {
                    for var k in kids {
                        k.layer = o.layer
                        k.fileID = 0
                        result.append(k)
                        newIDs.insert(k.id)
                    }
                } else {
                    result.append(o)
                }
            }
            doc.objects = result
        }
        if !newIDs.isEmpty { selection = newIDs }
    }

    // MARK: Layers

    func addLayer() {
        mutate("Add Layer") { doc in
            let index = (doc.layers.map { $0.index }.max() ?? 0) + 1
            doc.layers.append(Layer(name: "Layer \(index)", index: index))
        }
        activeLayer = doc.layers.last?.index ?? activeLayer
    }

    func deleteLayer(_ layer: Layer) {
        guard doc.layers.count > 1, let fallback = doc.layers.first(where: { $0.id != layer.id }) else { return }
        mutate("Delete Layer") { doc in
            doc.layers.removeAll { $0.id == layer.id }
            for i in doc.objects.indices where doc.objects[i].layer == layer.index { doc.objects[i].layer = fallback.index }
        }
        if activeLayer == layer.index { activeLayer = fallback.index }
    }

    func updateLayer(_ id: UUID, actionName: String = "Change Layer", _ body: (inout Layer) -> Void) {
        mutate(actionName) { doc in
            if let i = doc.layers.firstIndex(where: { $0.id == id }) { body(&doc.layers[i]) }
        }
    }

    /// Reorders layers. Indices are in the list's top-to-bottom display order.
    func moveLayers(from source: IndexSet, to destination: Int) {
        mutate("Reorder Layers") { doc in
            var display = Array(doc.layers.reversed())
            display.move(fromOffsets: source, toOffset: destination)
            doc.layers = Array(display.reversed())
        }
    }

    /// Reorders the objects of one layer. Indices are in top-to-bottom display order within that layer.
    func moveObjects(inLayer layerIndex: Int, from source: IndexSet, to destination: Int) {
        mutate("Reorder Objects") { doc in
            var inLayer = doc.objects.filter { $0.layer == layerIndex }.reversed().map { $0 }
            inLayer.move(fromOffsets: source, toOffset: destination)
            let ordered = Array(inLayer.reversed())
            var k = 0
            for i in doc.objects.indices where doc.objects[i].layer == layerIndex {
                doc.objects[i] = ordered[k]
                k += 1
            }
        }
    }

    // MARK: View

    func zoomToFit(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let page = doc.pageSize
        let s = min(size.width / page.width, size.height / page.height) * 0.9
        zoom = max(0.05, s)
        origin = CGPoint(x: (size.width - page.width * zoom) / 2, y: (size.height - page.height * zoom) / 2)
        needsZoomToFit = false
        hasUserAdjustedView = false
    }

    func zoom(by factor: CGFloat, around viewPoint: CGPoint? = nil) {
        hasUserAdjustedView = true
        let anchor = viewPoint ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let newZoom = max(0.05, min(200, zoom * factor))
        let mm = CGPoint(x: (anchor.x - origin.x) / zoom, y: (anchor.y - origin.y) / zoom)
        origin = CGPoint(x: anchor.x - mm.x * newZoom, y: anchor.y - mm.y * newZoom)
        zoom = newZoom
    }

    func toView(_ p: TSDPoint) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(p.x) * zoom, y: origin.y + CGFloat(p.y) * zoom)
    }

    func toDocument(_ p: CGPoint) -> TSDPoint {
        TSDPoint(x: Double((p.x - origin.x) / zoom), y: Double((p.y - origin.y) / zoom))
    }
}

// MARK: - Colour bridging

extension RGB {
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }

    init?(_ color: Color) {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(r: UInt8(max(0, min(255, (ns.redComponent * 255).rounded()))),
                  g: UInt8(max(0, min(255, (ns.greenComponent * 255).rounded()))),
                  b: UInt8(max(0, min(255, (ns.blueComponent * 255).rounded()))))
    }
}
