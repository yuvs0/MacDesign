#if os(macOS)
import SwiftUI
import AppKit
import TSDKit

struct CanvasView: NSViewRepresentable {
    @ObservedObject var state: EditorState
    /// Passed so SwiftUI re-runs updateNSView whenever the document changes.
    let doc: TSDDocument

    func makeNSView(context: Context) -> DrawingCanvas {
        let v = DrawingCanvas()
        v.controller.state = state
        return v
    }

    func updateNSView(_ view: DrawingCanvas, context: Context) {
        view.controller.state = state
        state.undoManager = context.environment.undoManager
        if state.needsZoomToFit, view.bounds.width > 10 {
            DispatchQueue.main.async { state.zoomToFit(in: view.bounds.size) }
        }
        view.needsDisplay = true
    }
}

/// AppKit host for the canvas: forwards mouse, keyboard, scroll and magnify events to the
/// controller. The view is not flipped, so its coordinates are y-up like the file's.
final class DrawingCanvas: NSView, CanvasHost {
    let controller = CanvasController()
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        controller.host = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: CanvasHost

    func canvasNeedsDisplay() { needsDisplay = true }
    func toolChanged() { window?.invalidateCursorRects(for: self) }
    var isDarkAppearance: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // MARK: Setup

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        controller.layoutChanged(bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func layout() {
        super.layout()
        controller.layoutChanged(bounds)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller.layoutChanged(bounds)
    }

    override func resetCursorRects() {
        guard let s = controller.state else { return }
        switch s.tool {
        case .select, .directSelect: addCursorRect(bounds, cursor: .arrow)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        case .eraser: addCursorRect(bounds, cursor: .disappearingItem)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        controller.draw(in: ctx, bounds: bounds)
    }

    // MARK: Events

    private func mods(_ event: NSEvent) -> InputModifiers {
        var m: InputModifiers = []
        if event.modifierFlags.contains(.shift) { m.insert(.shift) }
        if event.modifierFlags.contains(.command) { m.insert(.command) }
        if event.modifierFlags.contains(.option) { m.insert(.option) }
        return m
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        controller.pointerDown(at: point(event), modifiers: mods(event), clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        controller.pointerDragged(to: point(event), modifiers: mods(event))
    }

    override func mouseUp(with event: NSEvent) {
        controller.pointerUp(at: point(event), modifiers: mods(event))
    }

    override func mouseMoved(with event: NSEvent) {
        controller.pointerMoved(to: point(event), modifiers: mods(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.prepareContextMenu(at: point(event))
        let menu = NSMenu()
        for item in controller.contextMenuItems() {
            if item.separatorBefore { menu.addItem(.separator()) }
            let i = NSMenuItem(title: item.title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
            i.target = self
            i.isEnabled = item.enabled
            i.representedObject = MenuAction(item.action)
            menu.addItem(i)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private final class MenuAction {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    override func keyDown(with event: NSEvent) {
        let m = mods(event)
        let key: CanvasKey?
        switch event.keyCode {
        case 51, 117: key = .delete
        case 53: key = .escape
        case 36, 76: key = .returnKey
        case 123: key = .left
        case 124: key = .right
        case 125: key = .down
        case 126: key = .up
        default: key = event.charactersIgnoringModifiers?.first.map { .character($0) }
        }
        if let key, controller.key(key, modifiers: m) { return }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let factor = 1 + (-event.scrollingDeltaY) * 0.01
            controller.magnify(by: max(0.5, min(2, factor)), around: point(event))
            controller.state?.hasUserAdjustedView = true
        } else {
            controller.scroll(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)
        }
    }

    override func magnify(with event: NSEvent) {
        controller.magnify(by: 1 + event.magnification, around: point(event))
    }
}
#endif
