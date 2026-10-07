#if os(iOS)
import SwiftUI
import UIKit
import TSDKit

struct CanvasView: UIViewRepresentable {
    @ObservedObject var state: EditorState
    /// Passed so SwiftUI re-runs updateUIView whenever the document changes.
    let doc: TSDDocument

    func makeUIView(context: Context) -> DrawingCanvas {
        let v = DrawingCanvas()
        v.controller.state = state
        return v
    }

    func updateUIView(_ view: DrawingCanvas, context: Context) {
        view.controller.state = state
        state.undoManager = context.environment.undoManager
        if state.needsZoomToFit, view.bounds.width > 10 {
            DispatchQueue.main.async { state.zoomToFit(in: view.bounds.size) }
        }
        view.setNeedsDisplay()
    }
}

/// UIKit host for the canvas. UIKit's coordinates run top-down, so the drawing context is
/// flipped and touch points are converted, and everything else works in the controller's
/// y-up space. One finger or the Pencil draws and selects; two fingers pan; pinch zooms.
final class DrawingCanvas: UIView, CanvasHost, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate, UIPencilInteractionDelegate {
    let controller = CanvasController()
    /// The touch currently driving the tool, so a second finger (pan or pinch) doesn't interfere.
    private var activeTouch: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        controller.host = self
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        contentMode = .redraw

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        addInteraction(UIContextMenuInteraction(delegate: self))
        addInteraction(UIPencilInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: CanvasHost

    func canvasNeedsDisplay() { setNeedsDisplay() }
    func toolChanged() {}
    var isDarkAppearance: Bool { traitCollection.userInterfaceStyle == .dark }

    override func layoutSubviews() {
        super.layoutSubviews()
        controller.layoutChanged(bounds)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        controller.draw(in: ctx, bounds: bounds)
        ctx.restoreGState()
    }

    // MARK: Touches

    /// A touch's location in the controller's y-up coordinates.
    private func upPoint(_ touch: UITouch) -> CGPoint {
        let p = touch.preciseLocation(in: self)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private func upPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: bounds.height - p.y) }

    private func mods(_ event: UIEvent?) -> InputModifiers {
        var m: InputModifiers = []
        guard let flags = event?.modifierFlags else { return m }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.alternate) { m.insert(.option) }
        return m
    }

    /// In Pencil mode a finger always selects and moves, whatever tool the Pencil is using.
    private func toolOverride(for touch: UITouch) -> Tool? {
        guard controller.state?.inputMode == .pencil, touch.type != .pencil else { return nil }
        return .select
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        becomeFirstResponder()
        guard activeTouch == nil, let t = touches.first, event?.allTouches?.count ?? 1 == 1 else { return }
        activeTouch = t
        controller.pointerDown(at: upPoint(t), modifiers: mods(event), clickCount: t.tapCount, using: toolOverride(for: t))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        // A second finger means the user wants to pan or zoom, not draw.
        if event?.allTouches?.count ?? 1 > 1 { cancelActiveTouch(t, event: event); return }
        controller.pointerDragged(to: upPoint(t), modifiers: mods(event))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        activeTouch = nil
        controller.pointerUp(at: upPoint(t), modifiers: mods(event))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        cancelActiveTouch(t, event: event)
    }

    private func cancelActiveTouch(_ t: UITouch, event: UIEvent?) {
        activeTouch = nil
        // Finish the drag where it started, so nothing moves.
        controller.pointerUp(at: upPoint(t), modifiers: [.command])
    }

    // MARK: Gestures

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed else { return }
        controller.magnify(by: g.scale, around: upPoint(g.location(in: self)))
        g.scale = 1
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed else { return }
        let d = g.translation(in: self)
        controller.scroll(dx: d.x, dy: -d.y)
        g.setTranslation(.zero, in: self)
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard g.state == .changed || g.state == .began else { return }
        controller.pointerMoved(to: upPoint(g.location(in: self)), modifiers: [])
    }

    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }

    // MARK: Context menu (long press)

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        controller.prepareContextMenu(at: upPoint(location))
        let items = controller.contextMenuItems()
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var groups: [[UIAction]] = [[]]
            for item in items {
                if item.separatorBefore { groups.append([]) }
                let a = UIAction(title: item.title, attributes: item.enabled ? [] : .disabled) { _ in item.action() }
                groups[groups.count - 1].append(a)
            }
            return UIMenu(children: groups.map { UIMenu(options: .displayInline, children: $0) })
        }
    }

    /// No snapshot of the canvas: the menu should just open beside the point pressed.
    private func emptyPreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview {
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        anchor.backgroundColor = .clear
        let params = UIPreviewParameters()
        params.backgroundColor = .clear
        let target = UIPreviewTarget(container: self, center: interaction.location(in: self))
        return UITargetedPreview(view: anchor, parameters: params, target: target)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        emptyPreview(for: interaction)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        emptyPreview(for: interaction)
    }

    // MARK: Apple Pencil double tap

    /// Double tap switches between the Delete tool and the tool in use before it, the way
    /// other apps swap pen and eraser. Honours the Pencil setting that turns the tap off.
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        controller.state?.toggleEraser()
    }

    // MARK: Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        var cmds: [UIKeyCommand] = []
        for key in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputEscape] {
            cmds.append(UIKeyCommand(input: key, modifierFlags: [], action: #selector(keyCommand(_:))))
            cmds.append(UIKeyCommand(input: key, modifierFlags: .shift, action: #selector(keyCommand(_:))))
        }
        cmds.append(UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(keyCommand(_:))))
        cmds.append(UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(keyCommand(_:))))
        for tool in Tool.allCases {
            cmds.append(UIKeyCommand(input: String(tool.shortcut), modifierFlags: [], action: #selector(keyCommand(_:))))
        }
        for c in cmds { c.wantsPriorityOverSystemBehavior = true }
        return cmds
    }

    @objc private func keyCommand(_ cmd: UIKeyCommand) {
        var m: InputModifiers = []
        if cmd.modifierFlags.contains(.shift) { m.insert(.shift) }
        let key: CanvasKey?
        switch cmd.input {
        case UIKeyCommand.inputUpArrow: key = .up
        case UIKeyCommand.inputDownArrow: key = .down
        case UIKeyCommand.inputLeftArrow: key = .left
        case UIKeyCommand.inputRightArrow: key = .right
        case UIKeyCommand.inputEscape: key = .escape
        case "\u{8}": key = .delete
        case "\r": key = .returnKey
        default: key = cmd.input?.first.map { .character($0) }
        }
        if let key { controller.key(key, modifiers: m) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Delete arrives as a press rather than a key command on some keyboards.
        if presses.contains(where: { $0.key?.keyCode == .keyboardDeleteOrBackspace || $0.key?.keyCode == .keyboardDeleteForward }) {
            controller.key(.delete, modifiers: [])
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
#endif
