import Foundation
import CoreGraphics
import Combine
import TSDKit

/// Keyboard modifiers that matter to the canvas, independent of the input system.
struct InputModifiers: OptionSet {
    let rawValue: Int
    static let shift = InputModifiers(rawValue: 1)
    static let command = InputModifiers(rawValue: 2)
    static let option = InputModifiers(rawValue: 4)
}

enum CanvasKey {
    case delete, escape, returnKey, left, right, up, down
    case character(Character)
}

/// What the controller needs from the view that hosts it.
@MainActor
protocol CanvasHost: AnyObject {
    func canvasNeedsDisplay()
    /// The tool changed, so the pointer shape may need to.
    func toolChanged()
    var isDarkAppearance: Bool { get }
}

/// Everything the canvas does that isn't tied to AppKit or UIKit: drawing the page and
/// objects into a CGContext, and the tool state machine driven by pointer and key events.
/// View coordinates are y-up with the page's bottom-left at `state.origin`, matching the
/// file; the hosts convert to and from their own coordinate systems.
@MainActor
final class CanvasController {
    weak var host: CanvasHost?
    var state: EditorState? {
        didSet { host?.canvasNeedsDisplay() }
    }

    init() {
        // Grid settings live in user defaults and change from the View menu.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.host?.canvasNeedsDisplay() }
        }
    }

    private var defaultsObserver: NSObjectProtocol?

    private enum Drag {
        case none
        case marquee(start: TSDPoint, current: TSDPoint)
        case move(start: TSDPoint, current: TSDPoint, moved: Bool)
        case scale(handle: Int, bounds: TSDRect, current: TSDPoint)
        case create(start: TSDPoint, current: TSDPoint, shift: Bool)
        case penDrag(anchor: TSDPoint, current: TSDPoint)
        /// Direct selection: moving an anchor or handle of the selected path.
        case editPoint(objectID: UUID, part: PathEditing.Part, path: PathData, original: TSDKit.Shape, moved: Bool)
        /// Delete tool: everything swept over goes, as one undo step.
        case erase
    }

    private var drag: Drag = .none
    private var penSegments: [PathSegment] = []
    private var penOutHandle: TSDPoint?
    private var pointerLocation: TSDPoint?
    /// Modifiers of the most recent pointer event, for the resize constraint.
    private var modifiers: InputModifiers = []
    /// The tool driving the current press. Usually the editor's tool, but a host can ask
    /// for another one for a single press (iPad: fingers select while the Pencil draws).
    private var activeTool: Tool = .select

    // Snapping during a drag.
    private var snapper: Snapper?
    private var guides: [SnapGuide] = []
    private var haptics = SnapHaptics()
    /// Bounds of the selection when a move began.
    private var moveStartBounds: TSDRect?

    var bounds: CGRect = .zero

    // MARK: Fitting the page

    private var lastLaidOutSize: CGSize = .zero
    private var lastFitSize: CGSize = .zero
    private var fitScheduled = false

    /// Fits the page on first appearance and whenever the view is resized before the
    /// user has zoomed or panned themselves. State changes are deferred: publishing
    /// from inside a layout pass re-enters SwiftUI and throws.
    func layoutChanged(_ newBounds: CGRect) {
        bounds = newBounds
        guard let s = state else { return }
        s.viewSize = bounds.size
        let sizeChanged = abs(bounds.width - lastLaidOutSize.width) > 1 || abs(bounds.height - lastLaidOutSize.height) > 1
        lastLaidOutSize = bounds.size
        if bounds.width > 10, s.needsZoomToFit || (sizeChanged && !s.hasUserAdjustedView) {
            scheduleFit()
        }
    }

    func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let s = self.state else { return }
            self.fitScheduled = false
            guard self.bounds.width > 10 else { return }
            self.lastFitSize = self.bounds.size
            s.zoomToFit(in: self.bounds.size)
            self.host?.canvasNeedsDisplay()
        }
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, bounds viewBounds: CGRect) {
        bounds = viewBounds
        guard let s = state else { return }
        // The hosting view can resize without a layout pass; make sure the page fits
        // the actual bounds until the user takes over the view.
        if !s.hasUserAdjustedView, bounds.width > 10,
           abs(bounds.width - lastFitSize.width) > 1 || abs(bounds.height - lastFitSize.height) > 1 {
            scheduleFit()
        }
        let doc = s.doc
        let dark = host?.isDarkAppearance ?? false

        // Background and page.
        ctx.setFillColor(CGColor(gray: dark ? 0.16 : 0.90, alpha: 1))
        ctx.fill(bounds)
        let pageRect = CGRect(origin: s.origin, size: CGSize(width: doc.pageSize.width * s.zoom, height: doc.pageSize.height * s.zoom))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 12, color: CGColor(gray: 0, alpha: 0.25))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(pageRect)
        ctx.restoreGState()
        if GridPrefs.showGrid { drawGrid(in: ctx, state: s, pageRect: pageRect, dark: dark) }

        // Objects, in document space.
        ctx.saveGState()
        ctx.translateBy(x: s.origin.x, y: s.origin.y)
        ctx.scaleBy(x: s.zoom, y: s.zoom)
        var options = Renderer.Options()
        options.minimumStrokeWidth = 1.0 / Double(s.zoom)
        let live = liveTransform()
        let preview = s.filletPreviewObjects()
        var previewDrawn = false
        for o in doc.objects {
            if let preview, preview.replacing.contains(o.id) {
                // Draw the fillet preview once, in place of the first object it replaces.
                if !previewDrawn {
                    previewDrawn = true
                    for p in preview.with {
                        drawHalo(p, in: ctx, state: s)
                        Renderer.draw(p, in: ctx, doc: doc, options: options)
                    }
                }
                continue
            }
            var drawn = o
            if let m = live, s.selection.contains(o.id) {
                drawn = Geometry.transform(o, by: m)
            } else if case .editPoint(let id, _, let path, let original, true) = drag, o.id == id {
                drawn.shape = PathEditing.shape(after: path, original: original)
            }
            if s.selection.contains(o.id), s.tool != .pen {
                drawHalo(drawn, in: ctx, state: s)
            }
            Renderer.draw(drawn, in: ctx, doc: doc, options: options)
        }
        drawPreview(in: ctx, state: s)
        ctx.restoreGState()

        if s.tool == .directSelect {
            drawAnchors(in: ctx, state: s)
        } else {
            drawSelection(in: ctx, state: s, live: live)
        }
        drawGuides(in: ctx, state: s)
    }

    /// 2D Design's grid: fine black dots at every intersection, slightly larger at major
    /// ones. Dots that would be too dense at this zoom are left out. Measured from the
    /// page's bottom-left corner.
    private func drawGrid(in ctx: CGContext, state s: EditorState, pageRect: CGRect, dark: Bool) {
        let spacing = GridPrefs.spacing
        let majorEvery = GridPrefs.majorEvery
        let minPx = 6.0
        var step = spacing
        var multiple = 1
        while step * Double(s.zoom) < minPx { step *= 2; multiple *= 2 }
        let page = s.doc.pageSize
        ctx.saveGState()
        ctx.clip(to: pageRect)
        ctx.setFillColor(CGColor(gray: dark ? 0.1 : 0, alpha: 0.55))
        let minor = CGMutablePath(), major = CGMutablePath()
        var ix = 0
        var x = 0.0
        while x <= page.width + 1e-9 {
            var iy = 0
            var y = 0.0
            while y <= page.height + 1e-9 {
                let v = s.toView(TSDPoint(x: x, y: y))
                let isMajor = majorEvery > 1 && (ix * multiple) % majorEvery == 0 && (iy * multiple) % majorEvery == 0
                let r: CGFloat = isMajor ? 1.5 : 0.9
                (isMajor ? major : minor).addEllipse(in: CGRect(x: v.x.rounded() - r, y: v.y.rounded() - r, width: 2 * r, height: 2 * r))
                y += step; iy += 1
            }
            x += step; ix += 1
        }
        ctx.addPath(minor)
        ctx.fillPath()
        ctx.setFillColor(CGColor(gray: dark ? 0.1 : 0, alpha: 0.8))
        ctx.addPath(major)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func drawGuides(in ctx: CGContext, state s: EditorState) {
        guard !guides.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(Platform.guideColor)
        ctx.setLineWidth(1)
        let pad = 4.0 / Double(s.zoom) * 3
        for g in guides {
            switch g.axis {
            case .vertical:
                let a = s.toView(TSDPoint(x: g.position, y: g.from - pad)), b = s.toView(TSDPoint(x: g.position, y: g.to + pad))
                let x = a.x.rounded() + 0.5
                ctx.move(to: CGPoint(x: x, y: a.y)); ctx.addLine(to: CGPoint(x: x, y: b.y))
            case .horizontal:
                let a = s.toView(TSDPoint(x: g.from - pad, y: g.position)), b = s.toView(TSDPoint(x: g.to + pad, y: g.position))
                let y = a.y.rounded() + 0.5
                ctx.move(to: CGPoint(x: a.x, y: y)); ctx.addLine(to: CGPoint(x: b.x, y: y))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func liveTransform() -> Affine? {
        switch drag {
        case .move(let start, let current, let moved) where moved:
            return .translation(current.x - start.x, current.y - start.y)
        case .scale(let handle, let b, let current):
            return scaleTransform(handle: handle, bounds: b, to: current)
        default:
            return nil
        }
    }

    private func drawPreview(in ctx: CGContext, state s: EditorState) {
        let lw = 1.0 / Double(s.zoom)
        ctx.setLineWidth(lw)
        ctx.setStrokeColor(Platform.accentColor)
        if case .create(let start, let current, let shift) = drag, let shape = creationShape(tool: activeTool, start: start, end: current, shift: shift),
           let p = Renderer.cgPath(for: shape) {
            ctx.addPath(p)
            ctx.strokePath()
        }
        if s.tool == .pen, !penSegments.isEmpty {
            var preview = penSegments
            var handleLines: [(TSDPoint, TSDPoint)] = []
            let last = penSegments.last!.endPoint
            if case .penDrag(let anchor, let current) = drag {
                // Anchor just placed; show its handles.
                let mirrored = TSDPoint(x: 2 * anchor.x - current.x, y: 2 * anchor.y - current.y)
                handleLines.append((mirrored, current))
                if penSegments.count >= 1, penSegments.last!.endPoint != anchor {
                    preview.append(.curve(penOutHandle ?? last, mirrored, anchor))
                }
            } else if let m = pointerLocation {
                preview.append(penOutHandle != nil ? .curve(penOutHandle!, m, m) : .line(m))
            }
            ctx.addPath(Renderer.cgPath(for: PathData(segments: preview, isClosed: false)))
            ctx.strokePath()
            for (a, b) in handleLines {
                ctx.move(to: CGPoint(x: a.x, y: a.y)); ctx.addLine(to: CGPoint(x: b.x, y: b.y))
                ctx.strokePath()
                for p in [a, b] { ctx.fillEllipse(in: CGRect(x: p.x - 2 * lw, y: p.y - 2 * lw, width: 4 * lw, height: 4 * lw)) }
            }
            // Mark the first point so the user can close the path.
            if let first = penSegments.first?.endPoint {
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                let r = CGRect(x: first.x - 3 * lw, y: first.y - 3 * lw, width: 6 * lw, height: 6 * lw)
                ctx.fillEllipse(in: r); ctx.strokeEllipse(in: r)
            }
        }
    }

    /// A thin outline in the highlight colour just outside the object's own stroke. Drawn
    /// under the object, so only the part that sticks out past the stroke or fill shows.
    private func drawHalo(_ o: DesignObject, in ctx: CGContext, state s: EditorState) {
        guard let path = haloPath(o) else { return }
        let px = 1.0 / Double(s.zoom)
        ctx.saveGState()
        ctx.setStrokeColor(Platform.accentColor)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        let own = o.style.isStroked ? max(o.style.effectiveStrokeWidth, px) : 0
        ctx.setLineWidth(own + 2 * 2.5 * px)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func haloPath(_ o: DesignObject) -> CGPath? {
        switch o.shape {
        case .point(let p):
            return CGPath(ellipseIn: CGRect(x: p.x - 0.6, y: p.y - 0.6, width: 1.2, height: 1.2), transform: nil)
        case .group(let kids):
            let m = CGMutablePath()
            for k in kids { if let kp = haloPath(k) { m.addPath(kp) } }
            return m
        default:
            return Renderer.cgPath(for: o.shape)
        }
    }

    private func drawSelection(in ctx: CGContext, state s: EditorState, live: Affine?) {
        guard s.tool != .pen else { return }
        ctx.setStrokeColor(Platform.accentColor)
        ctx.setLineWidth(1)
        if let b = s.selectionBounds, live == nil, s.selectedObjects.allSatisfy({ s.isEditable($0) }) {
            let r = viewRect(b).insetBy(dx: -handleInset(s), dy: -handleInset(s))
            for p in handlePoints(r) {
                let hr = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(hr)
                ctx.stroke(hr)
            }
        }
        if case .marquee(let a, let c) = drag {
            let r = viewRect(TSDRect(p1: a, p2: c))
            ctx.setFillColor(Platform.accentColorTranslucent)
            ctx.fill(r)
            ctx.stroke(r)
        }
    }

    // MARK: Direct selection

    /// The path being edited: the live one during a drag, else the selected object's.
    private func directPath(_ s: EditorState) -> (DesignObject, PathData)? {
        guard s.selection.count == 1, let o = s.selectedObjects.first, s.isEditable(o) else { return nil }
        if case .editPoint(let id, _, let path, _, _) = drag, id == o.id { return (o, path) }
        guard let path = PathEditing.editablePath(o.shape) else { return nil }
        return (o, path)
    }

    private func drawAnchors(in ctx: CGContext, state s: EditorState) {
        let accent = Platform.accentColor
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1)
        guard let (_, path) = directPath(s) else { return }
        for i in s.selectedAnchors {
            let anchor = s.toView(path.segments[min(i, path.segments.count - 1)].endPoint)
            let h = PathEditing.handles(path, at: i)
            for hp in [h.inHandle, h.outHandle].compactMap({ $0 }) {
                let v = s.toView(hp)
                ctx.move(to: anchor); ctx.addLine(to: v); ctx.strokePath()
                ctx.setFillColor(accent)
                ctx.fillEllipse(in: CGRect(x: v.x - 3.5, y: v.y - 3.5, width: 7, height: 7))
            }
        }
        for (i, p) in PathEditing.anchors(path).enumerated() {
            let v = s.toView(p)
            let r = CGRect(x: v.x - 3.5, y: v.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(s.selectedAnchors.contains(i) ? accent : CGColor(gray: 1, alpha: 1))
            ctx.fill(r)
            ctx.stroke(r)
        }
    }

    /// The anchor or handle under a view point, handles of selected anchors taking priority.
    private func directPart(at vp: CGPoint, state s: EditorState) -> PathEditing.Part? {
        guard let (_, path) = directPath(s) else { return nil }
        let reach: CGFloat = Platform.isPad ? 12 : 6
        func near(_ p: TSDPoint) -> Bool { let v = s.toView(p); return abs(v.x - vp.x) <= reach && abs(v.y - vp.y) <= reach }
        for i in s.selectedAnchors {
            let h = PathEditing.handles(path, at: i)
            if let q = h.outHandle, near(q) { return .outHandle(i) }
            if let q = h.inHandle, near(q) { return .inHandle(i) }
        }
        for (i, p) in PathEditing.anchors(path).enumerated() where near(p) { return .anchor(i) }
        return nil
    }

    private func directPointerDown(viewPoint vp: CGPoint, docPoint p: TSDPoint, state s: EditorState) {
        let shift = modifiers.contains(.shift)
        if let part = directPart(at: vp, state: s), let (o, path) = directPath(s) {
            if case .anchor(let i) = part {
                if shift {
                    if s.selectedAnchors.contains(i) { s.selectedAnchors.remove(i) } else { s.selectedAnchors.insert(i) }
                } else if !s.selectedAnchors.contains(i) {
                    s.selectedAnchors = [i]
                }
            }
            beginSnapping(excluding: [o.id])
            drag = .editPoint(objectID: o.id, part: part, path: path, original: o.shape, moved: false)
            return
        }
        if let hit = hitTest(p) {
            if s.selection != [hit.id] { s.selectedAnchors = [] }
            s.selection = [hit.id]
            if PathEditing.editablePath(hit.shape) == nil {
                // Text, groups and points can't be point-edited; move them as a whole instead.
                beginSnapping(excluding: s.selection)
                moveStartBounds = s.selectionBounds
                drag = .move(start: p, current: p, moved: false)
            }
        } else {
            s.selection = []
            s.selectedAnchors = []
            drag = .marquee(start: p, current: p)
        }
    }

    /// Moves every selected anchor together when one of them is dragged.
    private func dragEditPoint(objectID: UUID, part: PathEditing.Part, path: PathData, original: TSDKit.Shape, to p: TSDPoint) {
        guard let s = state else { return }
        var q = snapped(p)
        if modifiers.contains(.shift), let from = PathEditing.position(of: part, in: path) {
            if abs(q.x - from.x) > abs(q.y - from.y) { q.y = from.y } else { q.x = from.x }
        }
        var newPath = PathEditing.move(part, to: q, in: path)
        if case .anchor(let i) = part, s.selectedAnchors.count > 1, let from = PathEditing.position(of: part, in: path) {
            let dx = q.x - from.x, dy = q.y - from.y
            for j in s.selectedAnchors where j != i {
                if let a = PathEditing.position(of: .anchor(j), in: path) {
                    newPath = PathEditing.move(.anchor(j), to: TSDPoint(x: a.x + dx, y: a.y + dy), in: newPath)
                }
            }
        }
        drag = .editPoint(objectID: objectID, part: part, path: newPath, original: original, moved: true)
    }

    // MARK: Snapping

    /// Snapping is on unless Command is held during the drag.
    private var snappingEnabled: Bool { !modifiers.contains(.command) }

    private func beginSnapping(excluding ids: Set<UUID>) {
        guard let s = state else { return }
        snapper = Snapper(state: s, excluding: ids, enabled: true)
        haptics.reset()
        guides = []
    }

    /// Snaps a point if snapping is on, updating the guides and haptics.
    private func snapped(_ p: TSDPoint) -> TSDPoint {
        guard let snapper, snappingEnabled else { guides = []; haptics.reset(); return p }
        let (q, result) = snapper.snap(point: p)
        guides = result.guides
        haptics.update(result.objectSnapKey)
        return q
    }

    private func endSnapping() {
        snapper = nil
        guides = []
        haptics.reset()
        moveStartBounds = nil
    }

    // MARK: Geometry helpers

    private func viewRect(_ r: TSDRect) -> CGRect {
        guard let s = state else { return .zero }
        let a = s.toView(TSDPoint(x: r.minX, y: r.minY)), b = s.toView(TSDPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Handle order: 0 BL, 1 BM, 2 BR, 3 ML, 4 MR, 5 TL, 6 TM, 7 TR.
    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func scaleTransform(handle: Int, bounds b: TSDRect, to p: TSDPoint) -> Affine {
        let movesX = [0, 2, 3, 4, 5, 7].contains(handle)
        let movesY = [0, 1, 2, 5, 6, 7].contains(handle)
        let anchorX = [0, 3, 5].contains(handle) ? b.maxX : b.minX
        let anchorY = [0, 1, 2].contains(handle) ? b.maxY : b.minY
        var sx = 1.0, sy = 1.0
        if movesX, b.width > 1e-6 { sx = (p.x - anchorX) / (([0, 3, 5].contains(handle) ? b.minX : b.maxX) - anchorX) }
        if movesY, b.height > 1e-6 { sy = (p.y - anchorY) / (([0, 1, 2].contains(handle) ? b.minY : b.maxY) - anchorY) }
        if modifiers.contains(.shift) || !movesX || !movesY {
            if movesX && movesY { let u = max(abs(sx), abs(sy)); sx = sx < 0 ? -u : u; sy = sy < 0 ? -u : u }
        }
        sx = abs(sx) < 0.01 ? 0.01 : sx
        sy = abs(sy) < 0.01 ? 0.01 : sy
        return .scale(sx, sy, about: TSDPoint(x: anchorX, y: anchorY))
    }

    // MARK: Hit testing

    private func hitTest(_ p: TSDPoint) -> DesignObject? {
        guard let s = state else { return nil }
        let tol = (Platform.isPad ? 8.0 : 4.0) / Double(s.zoom)
        for o in s.doc.objects.reversed() where s.isEditable(o) {
            if hits(o, p, tol: tol) { return o }
        }
        return nil
    }

    private func hits(_ o: DesignObject, _ p: TSDPoint, tol: Double) -> Bool {
        switch o.shape {
        case .group(let kids):
            return kids.contains { hits($0, p, tol: tol) }
        case .text(let t):
            return Renderer.textBounds(t).insetBy(-tol).contains(p)
        case .point(let q):
            return p.distance(to: q) <= tol * 2
        default:
            guard let path = Renderer.cgPath(for: o.shape) else { return false }
            let cg = CGPoint(x: p.x, y: p.y)
            if o.style.isFilled, path.contains(cg, using: .evenOdd) { return true }
            let stroked = path.copy(strokingWithWidth: 2 * tol + o.style.effectiveStrokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 2)
            return stroked.contains(cg)
        }
    }

    /// Handles sit clear of the object, and further still from text so they don't cover the letters.
    private func handleInset(_ s: EditorState) -> CGFloat {
        s.selectedObjects.allSatisfy { if case .text = $0.shape { return true } else { return false } } ? 16 : 12
    }

    private func handleIndex(at viewPoint: CGPoint) -> Int? {
        guard let s = state, let b = s.selectionBounds, s.selectedObjects.allSatisfy({ s.isEditable($0) }) else { return nil }
        let r = viewRect(b).insetBy(dx: -handleInset(s), dy: -handleInset(s))
        let reach: CGFloat = Platform.isPad ? 14 : 6
        for (i, h) in handlePoints(r).enumerated() where abs(h.x - viewPoint.x) <= reach && abs(h.y - viewPoint.y) <= reach {
            return i
        }
        return nil
    }

    // MARK: Pointer input (view coordinates, y up)

    /// `tool` overrides the editor's tool for this press and the drag that follows it.
    func pointerDown(at vp: CGPoint, modifiers mods: InputModifiers, clickCount: Int, using tool: Tool? = nil) {
        guard let s = state else { return }
        modifiers = mods
        var p = s.toDocument(vp)
        let shift = mods.contains(.shift)
        let isDouble = clickCount >= 2
        activeTool = tool ?? s.tool

        switch activeTool {
        case .directSelect:
            directPointerDown(viewPoint: vp, docPoint: p, state: s)
        case .select:
            if let h = handleIndex(at: vp), let b = s.selectionBounds {
                beginSnapping(excluding: s.selection)
                drag = .scale(handle: h, bounds: b, current: p)
            } else if let hit = hitTest(p) {
                if isDouble, case .text = hit.shape {
                    s.selection = [hit.id]
                    s.showInspector = true
                    s.inspectorTab = .properties
                    s.focusTextRequest += 1
                    return
                }
                if shift {
                    if s.selection.contains(hit.id) { s.selection.remove(hit.id) } else { s.selection.insert(hit.id) }
                } else if !s.selection.contains(hit.id) {
                    s.selection = [hit.id]
                }
                beginSnapping(excluding: s.selection)
                moveStartBounds = s.selectionBounds
                drag = .move(start: p, current: p, moved: false)
            } else {
                if !shift { s.selection = [] }
                drag = .marquee(start: p, current: p)
            }
        case .rectangle, .ellipse, .line, .arc:
            // A press on a handle of the shape just drawn resizes it instead of starting another.
            if let h = handleIndex(at: vp), let b = s.selectionBounds {
                beginSnapping(excluding: s.selection)
                drag = .scale(handle: h, bounds: b, current: p)
                break
            }
            beginSnapping(excluding: [])
            p = snapped(p)
            drag = .create(start: p, current: p, shift: shift)
        case .pen:
            beginSnapping(excluding: [])
            p = snapped(p)
            if isDouble { finishPen(close: false); return }
            if let first = penSegments.first?.endPoint, penSegments.count >= 2, p.distance(to: first) <= (Platform.isPad ? 12.0 : 6.0) / Double(s.zoom) {
                finishPen(close: true)
                return
            }
            drag = .penDrag(anchor: p, current: p)
        case .text:
            if let hit = hitTest(p), case .text = hit.shape {
                s.selection = [hit.id]
                s.focusTextRequest += 1
            } else {
                beginSnapping(excluding: [])
                let origin = snapped(p)
                endSnapping()
                var t = TextData(string: "Text", origin: origin, fontFace: s.newTextFace, fontSize: s.newTextSize)
                t.anchor = .zero
                var style = s.newShapeStyle
                style.strokeColor = style.strokeColor ?? .black
                s.add(DesignObject(style: style, shape: .text(t)))
                s.tool = .select
                s.showInspector = true
                s.inspectorTab = .properties
                s.focusTextRequest += 1
                host?.toolChanged()
            }
        case .eraser:
            drag = .erase
            erase(at: p)
        }
        host?.canvasNeedsDisplay()
    }

    /// Open while a Delete-tool sweep has removed something, so the whole sweep undoes at once.
    private var eraseGroupOpen = false

    /// Deletes the topmost editable object under the point, if any.
    private func erase(at p: TSDPoint) {
        guard let s = state, let hit = hitTest(p) else { return }
        if !eraseGroupOpen { s.undoManager?.beginUndoGrouping(); eraseGroupOpen = true }
        s.selection = []
        s.mutate("Delete") { $0.remove(ids: [hit.id]) }
    }

    func pointerDragged(to vp: CGPoint, modifiers mods: InputModifiers) {
        guard let s = state else { return }
        modifiers = mods
        let p = s.toDocument(vp)
        switch drag {
        case .marquee(let start, _): drag = .marquee(start: start, current: p)
        case .move(let start, _, let wasMoved):
            let moved = wasMoved || p.distance(to: start) * Double(s.zoom) > 2
            var dx = p.x - start.x, dy = p.y - start.y
            let lockX = mods.contains(.shift) && abs(dx) <= abs(dy)
            let lockY = mods.contains(.shift) && abs(dx) > abs(dy)
            if lockX { dx = 0 }
            if lockY { dy = 0 }
            if moved, let snapper, snappingEnabled, let b = moveStartBounds {
                let result = snapper.snap(box: TSDRect(minX: b.minX + dx, minY: b.minY + dy, maxX: b.maxX + dx, maxY: b.maxY + dy))
                if !lockX { dx += result.offset.dx }
                if !lockY { dy += result.offset.dy }
                guides = result.guides.filter { ($0.axis == .vertical && !lockX) || ($0.axis == .horizontal && !lockY) }
                haptics.update(result.objectSnapKey)
            } else {
                guides = []
            }
            drag = .move(start: start, current: TSDPoint(x: start.x + dx, y: start.y + dy), moved: moved)
        case .scale(let h, let b, _): drag = .scale(handle: h, bounds: b, current: snapped(p))
        case .create(let start, _, _): drag = .create(start: start, current: snapped(p), shift: mods.contains(.shift))
        case .penDrag(let anchor, _): drag = .penDrag(anchor: anchor, current: p)
        case .editPoint(let id, let part, _, let original, _):
            // Always move from the path as it was when the drag began.
            if let o = s.doc.objects.first(where: { $0.id == id }), let base = PathEditing.editablePath(o.shape) {
                dragEditPoint(objectID: id, part: part, path: base, original: original, to: p)
            }
        case .erase: erase(at: p)
        case .none: break
        }
        host?.canvasNeedsDisplay()
    }

    func pointerUp(at vp: CGPoint, modifiers mods: InputModifiers) {
        guard let s = state else { return }
        modifiers = mods
        defer { endSnapping() }
        var p = s.toDocument(vp)
        // Use the snapped position from the last drag event.
        switch drag {
        case .scale(_, _, let c), .create(_, let c, _): p = c
        default: break
        }
        switch drag {
        case .marquee(let start, _) where activeTool == .directSelect:
            let r = TSDRect(p1: start, p2: p)
            if r.width * Double(s.zoom) > 3 || r.height * Double(s.zoom) > 3 {
                // Prefer anchors of an already selected path; otherwise select the objects inside.
                if let (_, path) = directPath(s) {
                    let inside = Set(PathEditing.anchors(path).enumerated().filter { r.contains($0.element) }.map { $0.offset })
                    if !inside.isEmpty { s.selectedAnchors = inside; break }
                }
                let hits = s.doc.objects.filter { o in
                    guard s.isEditable(o), let b = s.objectBounds(o) else { return false }
                    return b.intersects(r)
                }.map { $0.id }
                s.selection = Set(hits)
                s.selectedAnchors = []
            }
        case .marquee(let start, _):
            let r = TSDRect(p1: start, p2: p)
            if r.width * Double(s.zoom) > 3 || r.height * Double(s.zoom) > 3 {
                let hits = s.doc.objects.filter { o in
                    guard s.isEditable(o), let b = s.objectBounds(o) else { return false }
                    return b.intersects(r)
                }.map { $0.id }
                if mods.contains(.shift) { s.selection.formUnion(hits) } else { s.selection = Set(hits) }
            }
        case .move(let start, let current, let moved):
            if moved {
                s.transformSelection(.translation(current.x - start.x, current.y - start.y))
            }
        case .scale(let h, let b, _):
            s.transformSelection(scaleTransform(handle: h, bounds: b, to: p), actionName: "Resize")
        case .create(let start, _, let shift):
            if let shape = creationShape(tool: activeTool, start: start, end: p, shift: shift || mods.contains(.shift)),
               start.distance(to: p) * Double(s.zoom) > 3 {
                var style = s.newShapeStyle
                if case .line = shape { style.fillColor = nil }
                s.add(DesignObject(style: style, shape: shape))
            }
        case .editPoint(let id, _, let path, let original, let moved):
            if moved {
                let shape = PathEditing.shape(after: path, original: original)
                s.mutate("Move Point") { doc in
                    if let i = doc.objects.firstIndex(where: { $0.id == id }) {
                        doc.objects[i].shape = shape
                        doc.objects[i].recordType = nil
                        doc.objects[i].rawCirclePoint = nil
                    }
                }
            }
        case .penDrag(let anchor, let current):
            let dragged = anchor.distance(to: current) * Double(s.zoom) > 3
            let incoming = dragged ? TSDPoint(x: 2 * anchor.x - current.x, y: 2 * anchor.y - current.y) : nil
            if penSegments.isEmpty {
                penSegments = [.move(anchor)]
            } else if let out = penOutHandle {
                penSegments.append(.curve(out, incoming ?? anchor, anchor))
            } else if let inc = incoming {
                penSegments.append(.curve(penSegments.last!.endPoint, inc, anchor))
            } else {
                penSegments.append(.line(anchor))
            }
            penOutHandle = dragged ? current : nil
        case .erase:
            if eraseGroupOpen { s.undoManager?.endUndoGrouping(); eraseGroupOpen = false }
        case .none:
            break
        }
        drag = .none
        host?.canvasNeedsDisplay()
    }

    func pointerMoved(to vp: CGPoint, modifiers mods: InputModifiers) {
        guard let s = state else { return }
        modifiers = mods
        var p = s.toDocument(vp)
        if s.tool == .pen, !penSegments.isEmpty {
            // Show where the next point would snap.
            if snapper == nil { snapper = Snapper(state: s, excluding: [], enabled: true) }
            p = snapped(p)
            host?.canvasNeedsDisplay()
        }
        pointerLocation = p
    }

    /// Selects what's under a secondary click before a context menu is shown.
    func prepareContextMenu(at vp: CGPoint) {
        guard let s = state else { return }
        if let hit = hitTest(s.toDocument(vp)), !s.selection.contains(hit.id) { s.selection = [hit.id] }
    }

    struct MenuItem {
        var title: String
        var enabled: Bool
        var action: () -> Void
        var separatorBefore = false
    }

    func contextMenuItems() -> [MenuItem] {
        guard let s = state else { return [] }
        let has = !s.selection.isEmpty
        let hasGroup = s.selectedObjects.contains { if case .group = $0.shape { return true } else { return false } }
        return [
            MenuItem(title: "Bring to Front", enabled: has) { s.arrange(.front) },
            MenuItem(title: "Send to Back", enabled: has) { s.arrange(.back) },
            MenuItem(title: "Duplicate", enabled: has, action: { s.duplicateSelection() }, separatorBefore: true),
            MenuItem(title: "Delete", enabled: has) { s.deleteSelection() },
            MenuItem(title: "Group", enabled: s.selection.count >= 2, action: { s.groupSelection() }, separatorBefore: true),
            MenuItem(title: "Ungroup", enabled: hasGroup) { s.ungroupSelection() },
            MenuItem(title: "Make Path", enabled: has) { s.makePath() },
            MenuItem(title: "Explode…", enabled: has) { s.requestExplode() },
            MenuItem(title: "Fillet Corners…", enabled: has) { s.requestFillet() },
        ]
    }

    // MARK: Shape creation

    private func creationShape(tool: Tool, start: TSDPoint, end: TSDPoint, shift: Bool) -> TSDKit.Shape? {
        var e = end
        if shift, tool != .line {
            let d = max(abs(e.x - start.x), abs(e.y - start.y))
            e = TSDPoint(x: start.x + (e.x >= start.x ? d : -d), y: start.y + (e.y >= start.y ? d : -d))
        }
        let r = TSDRect(p1: start, p2: e)
        switch tool {
        case .rectangle:
            return .rect(r)
        case .ellipse:
            if abs(r.width - r.height) < 1e-9 { return .circle(center: r.center, radius: r.width / 2) }
            return .ellipse(center: r.center, rx: r.width / 2, ry: r.height / 2)
        case .arc:
            // Quarter arc inside the dragged box, like Illustrator's arc tool.
            let cx = e.x >= start.x ? r.minX : r.maxX
            let cy = e.y >= start.y ? r.minY : r.maxY
            let a0: Double = (e.x >= start.x) ? (e.y >= start.y ? 0 : 270) : (e.y >= start.y ? 90 : 180)
            return .arc(center: TSDPoint(x: cx, y: cy), rx: r.width, ry: r.height, startAngle: a0, endAngle: a0 + 90)
        case .line:
            if shift {
                let dx = e.x - start.x, dy = e.y - start.y
                let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                let len = (dx * dx + dy * dy).squareRoot()
                e = TSDPoint(x: start.x + len * cos(angle), y: start.y + len * sin(angle))
            }
            return .line(start, e)
        default:
            return nil
        }
    }

    func finishPen(close: Bool) {
        guard let s = state else { return }
        defer { penSegments = []; penOutHandle = nil; host?.canvasNeedsDisplay() }
        guard penSegments.count >= 2 else { return }
        var segs = penSegments
        if close, let first = segs.first?.endPoint {
            if let out = penOutHandle { segs.append(.curve(out, first, first)) }
        }
        var style = s.newShapeStyle
        if !close { style.fillColor = nil }
        s.add(DesignObject(style: style, shape: .path(PathData(segments: segs, isClosed: close))))
    }

    var isDrawingPenPath: Bool { !penSegments.isEmpty }

    // MARK: Keyboard

    /// Returns false when the key wasn't handled.
    @discardableResult
    func key(_ key: CanvasKey, modifiers mods: InputModifiers) -> Bool {
        guard let s = state else { return false }
        let step = mods.contains(.shift) ? 10.0 : 1.0
        switch key {
        case .delete:
            if s.tool == .pen, !penSegments.isEmpty { penSegments.removeLast(); penOutHandle = nil; host?.canvasNeedsDisplay() }
            else if s.tool == .directSelect, !s.selectedAnchors.isEmpty { s.deleteSelectedAnchors() }
            else { s.deleteSelection() }
        case .escape:
            if s.tool == .pen, !penSegments.isEmpty { finishPen(close: false) } else { s.selection = []; s.selectedAnchors = []; s.tool = .select }
            host?.toolChanged()
            host?.canvasNeedsDisplay()
        case .returnKey:
            if s.tool == .pen { finishPen(close: false) }
        case .left: s.nudge(dx: -step, dy: 0)
        case .right: s.nudge(dx: step, dy: 0)
        case .down: s.nudge(dx: 0, dy: -step)
        case .up: s.nudge(dx: 0, dy: step)
        case .character(let c):
            guard mods.isSubset(of: [.shift]), let tool = Tool.allCases.first(where: { $0.shortcut == Character(c.lowercased()) }) else { return false }
            if s.tool == .pen, !penSegments.isEmpty { finishPen(close: false) }
            s.tool = tool
            host?.toolChanged()
        }
        return true
    }

    // MARK: Zoom and pan

    func scroll(dx: CGFloat, dy: CGFloat) {
        guard let s = state else { return }
        s.hasUserAdjustedView = true
        s.origin = CGPoint(x: s.origin.x + dx, y: s.origin.y + dy)
        host?.canvasNeedsDisplay()
    }

    func magnify(by factor: CGFloat, around vp: CGPoint) {
        guard let s = state else { return }
        s.zoom(by: factor, around: vp)
        host?.canvasNeedsDisplay()
    }
}
