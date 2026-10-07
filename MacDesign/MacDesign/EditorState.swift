import SwiftUI
import Combine
import TSDKit

struct FilletPreview: Equatable {
    var radius: Double
    var style: FilletStyle
}

enum Tool: String, CaseIterable, Identifiable {
    case select, directSelect, rectangle, ellipse, line, arc, pen, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .directSelect: return "Direct Selection"
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
        case .select: return "cursorarrow"
        case .directSelect: return "point.topleft.down.to.point.bottomright.curvepath"
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
        case .directSelect: return "a"
        case .rectangle: return "r"
        case .ellipse: return "e"
        case .line: return "l"
        case .arc: return "c"
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

    func setStrokeEnabled(_ on: Bool) {
        setLineType(on ? .solid : .none)
    }

    /// Replaces the whole fill (used to turn hatch, gradient and pattern fills off and on).
    func setFill(_ fill: Fill) {
        if selection.isEmpty { newShapeStyle.fill = fill; return }
        updateSelected("Change Fill") { o in
            o.style.fill = fill
            if case .group(var kids) = o.shape {
                for i in kids.indices { kids[i].style.fill = fill }
                o.shape = .group(kids)
            }
        }
    }

    /// Style shown in the inspector: the single selected object's, the first selected, or the defaults.
    var inspectedStyle: Style {
        selectedObjects.first?.style ?? newShapeStyle
    }

    // MARK: Direct selection (point editing)

    /// Indices of the selected anchors of the direct-selection target (segment indices).
    @Published var selectedAnchors: Set<Int> = []

    /// Deletes the selected anchors from the selected path, keeping at least two points.
    func deleteSelectedAnchors() {
        guard selection.count == 1, let o = selectedObjects.first, !selectedAnchors.isEmpty,
              let path = PathEditing.editablePath(o.shape) else { return }
        var segs = path.segments
        let remove = selectedAnchors.sorted(by: >)
        for i in remove where i < segs.count { segs.remove(at: i) }
        guard segs.count >= 2 else { return }
        if case .move = segs[0] {} else { segs[0] = .move(segs[0].endPoint) }
        let id = o.id
        selectedAnchors = []
        mutate("Delete Points") { doc in
            if let i = doc.objects.firstIndex(where: { $0.id == id }) {
                doc.objects[i].shape = .path(PathData(segments: segs, isClosed: path.isClosed))
                doc.objects[i].recordType = nil
            }
        }
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

    // MARK: Align and distribute

    enum AlignEdge: CaseIterable {
        case left, centreX, right, top, centreY, bottom

        var title: String {
            switch self {
            case .left: return "Align Left Edges"
            case .centreX: return "Align Horizontal Centres"
            case .right: return "Align Right Edges"
            case .top: return "Align Top Edges"
            case .centreY: return "Align Vertical Centres"
            case .bottom: return "Align Bottom Edges"
            }
        }

        var shortTitle: String {
            switch self {
            case .left: return "Left"
            case .centreX: return "Centre"
            case .right: return "Right"
            case .top: return "Top"
            case .centreY: return "Middle"
            case .bottom: return "Bottom"
            }
        }

        var systemImage: String {
            switch self {
            case .left: return "align.horizontal.left"
            case .centreX: return "align.horizontal.center"
            case .right: return "align.horizontal.right"
            case .top: return "align.vertical.top"
            case .centreY: return "align.vertical.center"
            case .bottom: return "align.vertical.bottom"
            }
        }
    }

    /// With one object selected, alignment is to the page; with several, to their combined bounds.
    var alignsToPage: Bool { selection.count == 1 }

    func align(_ edge: AlignEdge) {
        let objs = selectedObjects.filter { isEditable($0) }
        guard !objs.isEmpty else { return }
        let page = TSDRect(minX: 0, minY: 0, maxX: doc.pageSize.width, maxY: doc.pageSize.height)
        guard let reference = objs.count == 1 ? page : selectionBounds else { return }
        var moves: [UUID: Affine] = [:]
        for o in objs {
            guard let b = objectBounds(o) else { continue }
            var dx = 0.0, dy = 0.0
            switch edge {
            case .left: dx = reference.minX - b.minX
            case .centreX: dx = reference.center.x - b.center.x
            case .right: dx = reference.maxX - b.maxX
            case .top: dy = reference.maxY - b.maxY
            case .centreY: dy = reference.center.y - b.center.y
            case .bottom: dy = reference.minY - b.minY
            }
            if abs(dx) > 1e-9 || abs(dy) > 1e-9 { moves[o.id] = .translation(dx, dy) }
        }
        apply(moves, actionName: "Align")
    }

    /// Spaces three or more objects so the gaps between them are equal, keeping the outer two in place.
    func distribute(horizontally: Bool) {
        let items = selectedObjects.filter { isEditable($0) }.compactMap { o in objectBounds(o).map { (o, $0) } }
        guard items.count >= 3 else { return }
        let sorted = items.sorted { horizontally ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }
        let start = horizontally ? sorted.first!.1.minX : sorted.first!.1.minY
        let end = horizontally ? sorted.map { $0.1.maxX }.max()! : sorted.map { $0.1.maxY }.max()!
        let total = sorted.reduce(0.0) { $0 + (horizontally ? $1.1.width : $1.1.height) }
        let gap = (end - start - total) / Double(sorted.count - 1)
        var cursor = start
        var moves: [UUID: Affine] = [:]
        for (o, b) in sorted {
            let current = horizontally ? b.minX : b.minY
            let d = cursor - current
            if abs(d) > 1e-9 { moves[o.id] = horizontally ? .translation(d, 0) : .translation(0, d) }
            cursor += (horizontally ? b.width : b.height) + gap
        }
        apply(moves, actionName: "Distribute")
    }

    private func apply(_ moves: [UUID: Affine], actionName: String) {
        guard !moves.isEmpty else { return }
        mutate(actionName) { doc in
            for i in doc.objects.indices {
                if let m = moves[doc.objects[i].id] { doc.objects[i] = Geometry.transform(doc.objects[i], by: m) }
            }
        }
    }

    // MARK: Make Path and Explode

    /// Joins the selected objects' paths wherever their ends touch. One contiguous run becomes
    /// a single path; several runs become a group of paths.
    func makePath() {
        let objs = selectedObjects.filter { isEditable($0) }
        guard !objs.isEmpty else { return }
        let ids = Set(objs.map { $0.id })
        let parts = PathOps.makePath(objs)
        guard !parts.isEmpty else { return }
        var newID = UUID()
        mutate("Make Path") { doc in
            guard let at = doc.objects.firstIndex(where: { ids.contains($0.id) }) else { return }
            doc.objects.removeAll { ids.contains($0.id) }
            let result = parts.count == 1 ? parts[0] : DesignObject(layer: parts[0].layer, shape: .group(parts))
            newID = result.id
            doc.objects.insert(result, at: min(at, doc.objects.count))
        }
        selection = [newID]
        selectedAnchors = []
    }

    /// Set to show the Explode chooser (one level or fully).
    @Published var explodeRequest = false
    /// Set to show the Fillet sheet.
    @Published var filletRequest = false
    /// Set to show Settings as a sheet (iPad; the Mac has a Settings window).
    @Published var settingsRequest = false
    /// While the Fillet sheet is open: what it would do, drawn on the canvas in place of the selection.
    @Published var filletPreview: FilletPreview?

    /// The objects the preview replaces and what it draws instead, or nil when there's nothing to show.
    func filletPreviewObjects() -> (replacing: Set<UUID>, with: [DesignObject])? {
        guard let pv = filletPreview else { return nil }
        let objs = selectedObjects.filter { isEditable($0) }
        guard !objs.isEmpty else { return nil }
        if objs.count >= 2 {
            guard let (joined, result) = Fillet.joinAndFillet(objs, radius: pv.radius, style: pv.style), result.count > 0 else { return nil }
            return (Set(objs.map { $0.id }), [joined])
        }
        let o = objs[0]
        guard let path = PathEditing.editablePath(o.shape) else { return nil }
        let corners: Set<Int>? = selectedAnchors.isEmpty ? nil : Set(selectedAnchors.map { min($0, path.segments.count - 1) })
        let result = Fillet.apply(to: path, corners: corners, radius: pv.radius, style: pv.style)
        guard result.count > 0 else { return nil }
        var preview = o
        preview.shape = .path(result.path)
        return ([o.id], [preview])
    }

    /// Shows a message at the bottom of the canvas for a few seconds.
    func flash(_ message: String) {
        statusMessage = message
        let shown = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if statusMessage == shown { statusMessage = nil }
        }
    }

    // MARK: Fillet

    /// What the Fillet sheet will round, or why it can't.
    var filletDescription: String {
        let objs = selectedObjects.filter { isEditable($0) }
        if objs.count >= 2 { return "Joins the \(objs.count) selected objects and rounds the corners where they meet." }
        guard objs.count == 1 else { return "Select two touching lines or paths, or a path." }
        if PathEditing.editablePath(objs[0].shape) == nil { return "This object has no corners to round." }
        if selectedAnchors.isEmpty { return "Rounds every corner of the selected path." }
        return "Rounds the \(selectedAnchors.count) selected corner\(selectedAnchors.count == 1 ? "" : "s")."
    }

    func requestFillet() {
        let objs = selectedObjects.filter { isEditable($0) }
        guard !objs.isEmpty, objs.allSatisfy({ PathEditing.editablePath($0.shape) != nil || { if case .group = $0.shape { return true } else { return false } }($0) }) else {
            Platform.beep(); flash("Select two touching lines or paths, or a path with corners."); return
        }
        filletRequest = true
    }

    /// Rounds corners. Two or more objects: joined where they touch and filleted at the joins.
    /// One path: the selected anchors, or every corner when none are selected.
    func fillet(radius: Double, style: FilletStyle) {
        let objs = selectedObjects.filter { isEditable($0) }
        guard !objs.isEmpty else { return }
        if objs.count >= 2 {
            guard let (joined, result) = Fillet.joinAndFillet(objs, radius: radius, style: style) else {
                Platform.beep(); flash("The objects don't touch end to end, so they can't be joined."); return
            }
            guard result.count > 0 else { Platform.beep(); flash(result.reason ?? "Nothing to fillet."); return }
            let ids = Set(objs.map { $0.id })
            var newID = UUID()
            mutate("Fillet") { doc in
                guard let at = doc.objects.firstIndex(where: { ids.contains($0.id) }) else { return }
                doc.objects.removeAll { ids.contains($0.id) }
                newID = joined.id
                doc.objects.insert(joined, at: min(at, doc.objects.count))
            }
            selection = [newID]
            selectedAnchors = []
            flash("Rounded \(result.count) corner\(result.count == 1 ? "" : "s").")
            return
        }
        let o = objs[0]
        guard let path = PathEditing.editablePath(o.shape) else { Platform.beep(); flash("This object has no corners to round."); return }
        // Ring node k is path anchor k, except that a closed path's repeated end is dropped.
        let corners: Set<Int>? = selectedAnchors.isEmpty ? nil : Set(selectedAnchors.map { min($0, path.segments.count - 1) })
        let result = Fillet.apply(to: path, corners: corners, radius: radius, style: style)
        guard result.count > 0 else { Platform.beep(); flash(result.reason ?? "Nothing to fillet."); return }
        let id = o.id
        mutate("Fillet") { doc in
            if let i = doc.objects.firstIndex(where: { $0.id == id }) {
                doc.objects[i].shape = .path(result.path)
                doc.objects[i].recordType = nil
                doc.objects[i].rawCirclePoint = nil
            }
        }
        selectedAnchors = []
        flash("Rounded \(result.count) corner\(result.count == 1 ? "" : "s").")
    }

    func requestExplode() {
        guard selectedObjects.contains(where: { isEditable($0) && !PathOps.isPrimitive($0) }) else { Platform.beep(); return }
        explodeRequest = true
    }

    /// Splits each selected object. One level: groups into members, paths into their
    /// separate runs, a single run into its segments. Fully: down to primitives.
    func explode(fully: Bool) {
        let ids = selection
        guard !ids.isEmpty else { return }
        var newIDs: Set<UUID> = []
        mutate(fully ? "Explode Fully" : "Explode") { doc in
            var result: [DesignObject] = []
            for o in doc.objects {
                if ids.contains(o.id), isEditable(o) {
                    let parts = fully ? PathOps.explodeFully(o) : PathOps.explode(o)
                    result.append(contentsOf: parts)
                    newIDs.formUnion(parts.map { $0.id })
                } else {
                    result.append(o)
                }
            }
            doc.objects = result
        }
        selection = newIDs
        selectedAnchors = []
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
