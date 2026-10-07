import Foundation
import TSDKit
#if os(macOS)
import AppKit
#endif

/// Grid and snapping preferences, shared by all windows and kept in user defaults.
/// The View menu edits them through @AppStorage with the same keys.
/// 2D Design's lock modes: grid lock snaps to the grid, step lock to the 1 mm sub-grid.
enum LockMode: String, CaseIterable {
    case grid, step, none

    var title: String {
        switch self {
        case .grid: return "Grid Lock"
        case .step: return "Step Lock"
        case .none: return "No Lock"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "squareshape.split.2x2"
        case .step: return "squareshape.split.3x3"
        case .none: return "circle.dashed"
        }
    }

    var next: LockMode {
        switch self {
        case .grid: return .step
        case .step: return .none
        case .none: return .grid
        }
    }
}

enum GridPrefs {
    static let showGridKey = "showGrid"
    static let lockModeKey = "lockMode"
    static let stepSpacing = 1.0
    static let snapToObjectsKey = "snapToObjects"
    static let gridSpacingKey = "gridSpacing"
    static let majorEveryKey = "gridMajorEvery"
    static let hapticsKey = "snapHaptics"

    static let spacingPresets: [Double] = [1, 2, 2.5, 5, 10, 20, 25, 50]
    static let majorPresets: [Int] = [1, 2, 4, 5, 10]

    static func register() {
        UserDefaults.standard.register(defaults: [
            // 2D Design's defaults: a 10 mm grid with grid lock on.
            showGridKey: true,
            lockModeKey: LockMode.grid.rawValue,
            snapToObjectsKey: true,
            gridSpacingKey: 10.0,
            majorEveryKey: 1,
            hapticsKey: true,
        ])
    }

    static var showGrid: Bool { UserDefaults.standard.bool(forKey: showGridKey) }
    static var lockMode: LockMode {
        LockMode(rawValue: UserDefaults.standard.string(forKey: lockModeKey) ?? "") ?? .grid
    }
    static var snapToObjects: Bool { UserDefaults.standard.bool(forKey: snapToObjectsKey) }
    static var haptics: Bool { UserDefaults.standard.bool(forKey: hapticsKey) }
    static var spacing: Double {
        let v = UserDefaults.standard.double(forKey: gridSpacingKey)
        return v > 0 ? v : 10
    }
    static var majorEvery: Int { max(1, UserDefaults.standard.integer(forKey: majorEveryKey)) }

    static func spacingLabel(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v)) mm" : "\(v) mm"
    }

    /// Asks for a custom grid spacing.
    @MainActor
    static func askForCustomSpacing() {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "Grid Spacing"
        alert.informativeText = "Distance between grid lines, in millimetres."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = String(spacing)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.replacingOccurrences(of: ",", with: ".")
        if let v = Double(text), v >= 0.1, v <= 500 {
            UserDefaults.standard.set(v, forKey: gridSpacingKey)
        } else {
            Platform.beep()
        }
        #endif
    }
}

/// A line drawn while something is snapped to another object or the page.
struct SnapGuide: Equatable {
    enum Axis { case vertical, horizontal }
    var axis: Axis
    /// x for a vertical guide, y for a horizontal one (mm).
    var position: Double
    /// Extent along the guide (mm).
    var from: Double
    var to: Double
}

/// Snaps points and moving boxes to the grid, other objects' edges and centres, and the page.
struct Snapper {
    struct Target {
        var value: Double
        /// Extent of the thing that owns this edge, along the other axis (for drawing guides).
        var span: ClosedRange<Double>
    }

    var xs: [Target] = []
    var ys: [Target] = []
    var gridSpacing: Double?
    /// Snap distance in mm (a few screen points at the current zoom).
    var tolerance: Double

    /// Collects targets from every visible object except `excluding`, plus the page.
    @MainActor
    init(state: EditorState, excluding: Set<UUID>, enabled: Bool) {
        tolerance = 6 / Double(state.zoom)
        guard enabled else { return }
        switch GridPrefs.lockMode {
        case .grid: gridSpacing = GridPrefs.spacing
        case .step: gridSpacing = GridPrefs.stepSpacing
        case .none: gridSpacing = nil
        }
        guard GridPrefs.snapToObjects else { return }
        let page = state.doc.pageSize
        for x in [0, page.width / 2, page.width] { xs.append(Target(value: x, span: 0...page.height)) }
        for y in [0, page.height / 2, page.height] { ys.append(Target(value: y, span: 0...page.width)) }
        for o in state.doc.objects where !excluding.contains(o.id) && o.isVisible {
            if let layer = state.doc.layer(withIndex: o.layer), !layer.isVisible { continue }
            guard let b = state.objectBounds(o) else { continue }
            for x in [b.minX, b.center.x, b.maxX] { xs.append(Target(value: x, span: b.minY...b.maxY)) }
            for y in [b.minY, b.center.y, b.maxY] { ys.append(Target(value: y, span: b.minX...b.maxX)) }
            // Corners and vertices of paths, so lines and pen points can meet them.
            if let path = Geometry.path(for: o.shape), path.segments.count <= 400 {
                for p in path.segments.map(\.endPoint) {
                    xs.append(Target(value: p.x, span: p.y...p.y))
                    ys.append(Target(value: p.y, span: p.x...p.x))
                }
            }
        }
    }

    struct Result {
        var offset: (dx: Double, dy: Double) = (0, 0)
        var guides: [SnapGuide] = []
        /// Values snapped to on objects or the page, used to decide when to play a haptic.
        var objectSnapKey: [Double] = []
    }

    /// Best adjustment for any of `values` to meet a target, within tolerance.
    private func nearest(_ values: [Double], in targets: [Target]) -> (delta: Double, target: Target, value: Double)? {
        var best: (Double, Target, Double)?
        for v in values {
            for t in targets {
                let d = t.value - v
                if abs(d) <= tolerance, best == nil || abs(d) < abs(best!.0) { best = (d, t, v) }
            }
        }
        return best
    }

    private func gridDelta(_ v: Double) -> Double? {
        guard let g = gridSpacing, g > 0 else { return nil }
        return (v / g).rounded() * g - v
    }

    /// Snaps a single point (drawing, resizing, pen anchors). With grid lock on, the grid
    /// wins as in 2D Design; an object edge only takes over when it's closer than the grid.
    func snap(point p: TSDPoint) -> (TSDPoint, Result) {
        var r = Result()
        var q = p
        let gx = gridDelta(p.x), gy = gridDelta(p.y)
        if let hit = nearest([p.x], in: xs), gx == nil || abs(hit.delta) < abs(gx!) {
            q.x += hit.delta
            r.guides.append(SnapGuide(axis: .vertical, position: hit.target.value,
                                      from: min(hit.target.span.lowerBound, p.y), to: max(hit.target.span.upperBound, p.y)))
            r.objectSnapKey.append(hit.target.value)
        } else if let d = gx {
            q.x += d
        }
        if let hit = nearest([p.y], in: ys), gy == nil || abs(hit.delta) < abs(gy!) {
            q.y += hit.delta
            r.guides.append(SnapGuide(axis: .horizontal, position: hit.target.value,
                                      from: min(hit.target.span.lowerBound, p.x), to: max(hit.target.span.upperBound, p.x)))
            r.objectSnapKey.append(hit.target.value + 1e6)
        } else if let d = gy {
            q.y += d
        }
        r.offset = (q.x - p.x, q.y - p.y)
        return (q, r)
    }

    /// Snaps a box being moved: its edges and centre meet other objects, or its top-left
    /// corner sits on the grid, whichever is nearer.
    func snap(box b: TSDRect) -> Result {
        var r = Result()
        let gx = gridDelta(b.minX), gy = gridDelta(b.maxY)
        if let hit = nearest([b.minX, b.center.x, b.maxX], in: xs), gx == nil || abs(hit.delta) < abs(gx!) {
            r.offset.dx = hit.delta
            r.guides.append(SnapGuide(axis: .vertical, position: hit.target.value,
                                      from: min(hit.target.span.lowerBound, b.minY), to: max(hit.target.span.upperBound, b.maxY)))
            r.objectSnapKey.append(hit.target.value)
        } else if let d = gx {
            r.offset.dx = d
        }
        if let hit = nearest([b.minY, b.center.y, b.maxY], in: ys), gy == nil || abs(hit.delta) < abs(gy!) {
            r.offset.dy = hit.delta
            r.guides.append(SnapGuide(axis: .horizontal, position: hit.target.value,
                                      from: min(hit.target.span.lowerBound, b.minX), to: max(hit.target.span.upperBound, b.maxX)))
            r.objectSnapKey.append(hit.target.value + 1e6)
        } else if let d = gy {
            r.offset.dy = d
        }
        return r
    }
}

/// Plays the trackpad's alignment click when a new snap engages, like Keynote and Freeform.
struct SnapHaptics {
    private var lastKey: [Double] = []

    mutating func update(_ key: [Double]) {
        defer { lastKey = key }
        guard !key.isEmpty, key != lastKey, GridPrefs.haptics else { return }
        // Only when something new engages, not when a snap is released.
        if !Set(key).isSubset(of: Set(lastKey)) {
            Platform.snapHaptic()
        }
    }

    mutating func reset() { lastKey = [] }
}
