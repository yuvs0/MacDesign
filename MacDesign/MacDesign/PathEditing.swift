import Foundation
import TSDKit

/// Anchor and handle editing for the direct selection tool. Every editable shape is
/// treated as a path: lines, rectangles, ellipses, circles and arcs are converted on the
/// first edit.
enum PathEditing {
    /// Which part of a path a drag moves.
    enum Part: Equatable {
        /// The end point of segment `index` (and its attached control points).
        case anchor(Int)
        /// The outgoing handle of anchor `index`: control 1 of segment index + 1.
        case outHandle(Int)
        /// The incoming handle of anchor `index`: control 2 of segment index.
        case inHandle(Int)
    }

    /// The shape as a path, or nil for text, points and groups.
    static func editablePath(_ shape: Shape) -> PathData? {
        switch shape {
        case .text, .point, .group: return nil
        default: return Geometry.path(for: shape)
        }
    }

    static func anchors(_ path: PathData) -> [TSDPoint] {
        path.segments.map(\.endPoint)
    }

    /// Handle positions shown for a selected anchor: (in, out), either may be nil.
    static func handles(_ path: PathData, at index: Int) -> (inHandle: TSDPoint?, outHandle: TSDPoint?) {
        var inH: TSDPoint?, outH: TSDPoint?
        if index < path.segments.count, case .curve(_, let c2, _) = path.segments[index] { inH = c2 }
        if index + 1 < path.segments.count, case .curve(let c1, _, _) = path.segments[index + 1] { outH = c1 }
        return (inH, outH)
    }

    static func position(of part: Part, in path: PathData) -> TSDPoint? {
        switch part {
        case .anchor(let i): return i < path.segments.count ? path.segments[i].endPoint : nil
        case .inHandle(let i): return handles(path, at: i).inHandle
        case .outHandle(let i): return handles(path, at: i).outHandle
        }
    }

    /// Moves `part` so it sits at `p`. Moving an anchor carries its handles with it; moving a
    /// handle leaves its anchor and the other handle alone (no smooth-point constraint).
    static func move(_ part: Part, to p: TSDPoint, in path: PathData) -> PathData {
        var segs = path.segments
        switch part {
        case .anchor(let i):
            guard i < segs.count else { return path }
            let old = segs[i].endPoint
            let dx = p.x - old.x, dy = p.y - old.y
            func shift(_ q: TSDPoint) -> TSDPoint { TSDPoint(x: q.x + dx, y: q.y + dy) }
            switch segs[i] {
            case .move: segs[i] = .move(p)
            case .line: segs[i] = .line(p)
            case .curve(let c1, let c2, _): segs[i] = .curve(c1, shift(c2), p)
            }
            if i + 1 < segs.count, case .curve(let c1, let c2, let e) = segs[i + 1] {
                segs[i + 1] = .curve(shift(c1), c2, e)
            }
            // A closed path that repeats its first point as its last keeps them together.
            if path.isClosed, segs.count >= 2 {
                if i == 0, Geometry.near(old, segs[segs.count - 1].endPoint) {
                    segs[segs.count - 1] = replacingEnd(segs[segs.count - 1], with: p, shiftingControl2By: (dx, dy))
                } else if i == segs.count - 1, Geometry.near(old, segs[0].endPoint) {
                    segs[0] = .move(p)
                    if segs.count > 1, case .curve(let c1, let c2, let e) = segs[1] { segs[1] = .curve(shift(c1), c2, e) }
                }
            }
        case .inHandle(let i):
            guard i < segs.count, case .curve(let c1, _, let e) = segs[i] else { return path }
            segs[i] = .curve(c1, p, e)
        case .outHandle(let i):
            guard i + 1 < segs.count, case .curve(_, let c2, let e) = segs[i + 1] else { return path }
            segs[i + 1] = .curve(p, c2, e)
        }
        return PathData(segments: segs, isClosed: path.isClosed)
    }

    private static func replacingEnd(_ seg: PathSegment, with p: TSDPoint, shiftingControl2By d: (Double, Double)) -> PathSegment {
        switch seg {
        case .move: return .move(p)
        case .line: return .line(p)
        case .curve(let c1, let c2, _): return .curve(c1, TSDPoint(x: c2.x + d.0, y: c2.y + d.1), p)
        }
    }

    /// The edited shape. A line stays a line when only its ends move; everything else becomes a path.
    static func shape(after path: PathData, original: Shape) -> Shape {
        if case .line = original, path.segments.count == 2, case .move(let a) = path.segments[0], case .line(let b) = path.segments[1] {
            return .line(a, b)
        }
        return .path(path)
    }
}
