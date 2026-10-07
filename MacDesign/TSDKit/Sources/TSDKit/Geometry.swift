import Foundation

/// 2-D affine transform: x' = a*x + c*y + tx, y' = b*x + d*y + ty.
public struct Affine: Equatable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = Affine()

    public static func translation(_ dx: Double, _ dy: Double) -> Affine { Affine(tx: dx, ty: dy) }

    /// Scale about an anchor point.
    public static func scale(_ sx: Double, _ sy: Double, about p: TSDPoint) -> Affine {
        Affine(a: sx, d: sy, tx: p.x - sx * p.x, ty: p.y - sy * p.y)
    }

    public static func rotation(degrees: Double, about p: TSDPoint) -> Affine {
        let r = degrees * .pi / 180
        let cs = cos(r), sn = sin(r)
        return Affine(a: cs, b: sn, c: -sn, d: cs,
                      tx: p.x - cs * p.x + sn * p.y,
                      ty: p.y - sn * p.x - cs * p.y)
    }

    public func apply(_ p: TSDPoint) -> TSDPoint {
        TSDPoint(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty)
    }

    /// True when the transform keeps rectangles axis-aligned (translate and scale only).
    public var isAxisAligned: Bool { b == 0 && c == 0 }
    public var isTranslation: Bool { a == 1 && d == 1 && b == 0 && c == 0 }
}

public enum Geometry {
    /// Magic number for approximating a quarter circle with a cubic Bézier.
    static let kappa = 0.5522847498307936

    // MARK: Primitive to path

    /// The outline of any shape as path segments. Groups and points return nil.
    public static func path(for shape: Shape) -> PathData? {
        switch shape {
        case .path(let p):
            return p
        case .line(let a, let b):
            return PathData(segments: [.move(a), .line(b)], isClosed: false)
        case .circle(let c, let r):
            return ellipsePath(center: c, rx: r, ry: r)
        case .ellipse(let c, let rx, let ry):
            return ellipsePath(center: c, rx: rx, ry: ry)
        case .rect(let r):
            return PathData(segments: [
                .move(TSDPoint(x: r.minX, y: r.maxY)),
                .line(TSDPoint(x: r.maxX, y: r.maxY)),
                .line(TSDPoint(x: r.maxX, y: r.minY)),
                .line(TSDPoint(x: r.minX, y: r.minY)),
                .line(TSDPoint(x: r.minX, y: r.maxY)),
            ], isClosed: true)
        case .arc(let c, let rx, let ry, let a0, let a1):
            return arcPath(center: c, rx: rx, ry: ry, startAngle: a0, endAngle: a1)
        case .point, .text, .group:
            return nil
        }
    }

    public static func ellipsePath(center c: TSDPoint, rx: Double, ry: Double) -> PathData {
        let k = kappa
        let kx = rx * k, ky = ry * k
        let top = TSDPoint(x: c.x, y: c.y + ry)
        let right = TSDPoint(x: c.x + rx, y: c.y)
        let bottom = TSDPoint(x: c.x, y: c.y - ry)
        let left = TSDPoint(x: c.x - rx, y: c.y)
        return PathData(segments: [
            .move(top),
            .curve(TSDPoint(x: c.x + kx, y: c.y + ry), TSDPoint(x: c.x + rx, y: c.y + ky), right),
            .curve(TSDPoint(x: c.x + rx, y: c.y - ky), TSDPoint(x: c.x + kx, y: c.y - ry), bottom),
            .curve(TSDPoint(x: c.x - kx, y: c.y - ry), TSDPoint(x: c.x - rx, y: c.y - ky), left),
            .curve(TSDPoint(x: c.x - rx, y: c.y + ky), TSDPoint(x: c.x - kx, y: c.y + ry), top),
        ], isClosed: true)
    }

    /// Anticlockwise elliptical arc from startAngle to endAngle (degrees), split into pieces of at most 90°.
    public static func arcPath(center c: TSDPoint, rx: Double, ry: Double, startAngle: Double, endAngle: Double) -> PathData {
        var sweep = endAngle - startAngle
        while sweep <= 0 { sweep += 360 }
        if sweep > 360 { sweep = 360 }
        let pieces = max(1, Int(ceil(sweep / 90 - 1e-9)))
        let step = (sweep / Double(pieces)) * .pi / 180
        var theta = startAngle * .pi / 180
        func pt(_ t: Double) -> TSDPoint { TSDPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t)) }
        func deriv(_ t: Double) -> (Double, Double) { (-rx * sin(t), ry * cos(t)) }
        var segments: [PathSegment] = [.move(pt(theta))]
        let alpha = 4.0 / 3.0 * tan(step / 4)
        for _ in 0..<pieces {
            let t0 = theta, t1 = theta + step
            let p0 = pt(t0), p3 = pt(t1)
            let d0 = deriv(t0), d1 = deriv(t1)
            let c1 = TSDPoint(x: p0.x + alpha * d0.0, y: p0.y + alpha * d0.1)
            let c2 = TSDPoint(x: p3.x - alpha * d1.0, y: p3.y - alpha * d1.1)
            segments.append(.curve(c1, c2, p3))
            theta = t1
        }
        return PathData(segments: segments, isClosed: sweep >= 360 - 1e-9)
    }

    /// Closed outline of a polyline drawn `width` wide: both sides with mitred corners,
    /// joined by square ends. nil for fewer than two distinct points.
    public static func doubleLineOutline(_ points: [TSDPoint], width: Double) -> PathData? {
        var pts: [TSDPoint] = []
        for p in points where pts.last.map({ !near($0, p) }) ?? true { pts.append(p) }
        guard pts.count >= 2 else { return nil }
        let h = width / 2

        func side(_ sign: Double) -> [TSDPoint] {
            func normal(_ a: TSDPoint, _ b: TSDPoint) -> (Double, Double) {
                let dx = b.x - a.x, dy = b.y - a.y
                let l = max((dx * dx + dy * dy).squareRoot(), 1e-12)
                return (-dy / l * sign, dx / l * sign)
            }
            var out: [TSDPoint] = []
            for i in 0..<pts.count {
                if i == 0 || i == pts.count - 1 {
                    let n = i == 0 ? normal(pts[0], pts[1]) : normal(pts[i - 1], pts[i])
                    out.append(TSDPoint(x: pts[i].x + n.0 * h, y: pts[i].y + n.1 * h))
                    continue
                }
                let n1 = normal(pts[i - 1], pts[i]), n2 = normal(pts[i], pts[i + 1])
                // Mitre: along the bisector, length h / cos(half the turn).
                var mx = n1.0 + n2.0, my = n1.1 + n2.1
                let ml = (mx * mx + my * my).squareRoot()
                if ml < 1e-9 { mx = n1.0; my = n1.1 } else { mx /= ml; my /= ml }
                let cosHalf = max(mx * n1.0 + my * n1.1, 0.1)
                out.append(TSDPoint(x: pts[i].x + mx * h / cosHalf, y: pts[i].y + my * h / cosHalf))
            }
            return out
        }

        let left = side(1), right = side(-1)
        var segments: [PathSegment] = [.move(left[0])]
        for p in left.dropFirst() { segments.append(.line(p)) }
        for p in right.reversed() { segments.append(.line(p)) }
        segments.append(.line(left[0]))
        return PathData(segments: segments, isClosed: true)
    }

    // MARK: Recognising primitives in file paths

    /// Turns a path that is really an axis-aligned rectangle or an ellipse back into that primitive.
    public static func recognise(_ p: PathData) -> Shape {
        let s = p.segments
        // Rectangle: move + 4 lines returning to start, axis aligned.
        if s.count == 5, case .move(let p0) = s[0] {
            var pts = [p0]
            var allLines = true
            for seg in s.dropFirst() {
                if case .line(let q) = seg { pts.append(q) } else { allLines = false; break }
            }
            if allLines, near(pts[0], pts[4]) {
                let xs = pts.prefix(4).map { $0.x }, ys = pts.prefix(4).map { $0.y }
                let axisAligned = zip(pts, pts.dropFirst()).prefix(4).allSatisfy { a, b in
                    abs(a.x - b.x) < 1e-6 || abs(a.y - b.y) < 1e-6
                }
                if axisAligned, Set(xs.map { ($0 * 1e4).rounded() }).count == 2, Set(ys.map { ($0 * 1e4).rounded() }).count == 2 {
                    let r = TSDRect(minX: xs.min()!, minY: ys.min()!, maxX: xs.max()!, maxY: ys.max()!)
                    // Only when the corners run the way we write them, so the file round-trips exactly.
                    if near(pts[0], TSDPoint(x: r.minX, y: r.maxY)), near(pts[1], TSDPoint(x: r.maxX, y: r.maxY)) {
                        return .rect(r)
                    }
                }
            }
        }
        // Ellipse: move + 4 curves whose end points sit on the axes of a common centre.
        if s.count == 5, case .move(let p0) = s[0] {
            var ends = [p0]
            var allCurves = true
            for seg in s.dropFirst() {
                if case .curve(_, _, let e) = seg { ends.append(e) } else { allCurves = false; break }
            }
            if allCurves, near(ends[0], ends[4]) {
                let cx = (ends[0].x + ends[2].x) / 2, cy = (ends[0].y + ends[2].y) / 2
                let c2x = (ends[1].x + ends[3].x) / 2, c2y = (ends[1].y + ends[3].y) / 2
                if abs(cx - c2x) < 1e-3, abs(cy - c2y) < 1e-3 {
                    let center = TSDPoint(x: cx, y: cy)
                    let rx = max(abs(ends[0].x - cx), abs(ends[1].x - cx))
                    let ry = max(abs(ends[0].y - cy), abs(ends[1].y - cy))
                    let onAxes = ends.prefix(4).allSatisfy { e in
                        abs(e.x - cx) < 1e-3 || abs(e.y - cy) < 1e-3
                    }
                    if onAxes, rx > 0, ry > 0 {
                        // Check control points are where a Bézier ellipse would put them.
                        let expected = ellipsePath(center: center, rx: rx, ry: ry)
                        let pa = p.allPoints, pb = expected.allPoints
                        if pa.count == pb.count, zip(pa, pb).allSatisfy({ near($0, $1, 1e-6) }) {
                            return .ellipse(center: center, rx: rx, ry: ry)
                        }
                    }
                }
            }
        }
        return .path(p)
    }

    static func near(_ a: TSDPoint, _ b: TSDPoint, _ tol: Double = 1e-6) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
    }

    /// True when both paths have the same points within `tolerance`, allowing a different start corner.
    static func pathsMatch(_ a: PathData, _ b: PathData, tolerance: Double) -> Bool {
        let pa = a.allPoints, pb = b.allPoints
        guard pa.count == pb.count, !pa.isEmpty else { return false }
        for shift in 0..<pa.count {
            var ok = true
            for i in 0..<pa.count where !near(pa[i], pb[(i + shift) % pb.count], tolerance) {
                ok = false; break
            }
            if ok { return true }
        }
        // Also try reversed direction.
        let rb = Array(pb.reversed())
        for shift in 0..<pa.count {
            var ok = true
            for i in 0..<pa.count where !near(pa[i], rb[(i + shift) % rb.count], tolerance) {
                ok = false; break
            }
            if ok { return true }
        }
        return false
    }

    // MARK: Flattening

    /// Splits a path into polylines, flattening Bézier curves.
    public static func polylines(_ path: PathData, steps: Int = 16) -> [[TSDPoint]] {
        var runs: [[TSDPoint]] = []
        var current: [TSDPoint] = []
        for seg in path.segments {
            switch seg {
            case .move(let p):
                if current.count >= 2 { runs.append(current) }
                current = [p]
            case .line(let p):
                current.append(p)
            case .curve(let c1, let c2, let e):
                guard let s = current.last else { current = [e]; continue }
                let n = max(1, steps)
                for k in 1...n {
                    let t = Double(k) / Double(n), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    current.append(TSDPoint(x: a * s.x + b * c1.x + c * c2.x + d * e.x,
                                            y: a * s.y + b * c1.y + c * c2.y + d * e.y))
                }
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    /// Distance from a point to the nearest point on a path's outline.
    public static func distance(from p: TSDPoint, to path: PathData) -> Double {
        var best = Double.infinity
        for run in polylines(path, steps: 12) {
            for i in 0..<(run.count - 1) {
                best = min(best, distanceToSegment(p, run[i], run[i + 1]))
            }
            if path.isClosed, let f = run.first, let l = run.last {
                best = min(best, distanceToSegment(p, l, f))
            }
        }
        return best
    }

    public static func distanceToSegment(_ p: TSDPoint, _ a: TSDPoint, _ b: TSDPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return p.distance(to: a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return p.distance(to: TSDPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Even-odd test against the flattened outline.
    public static func contains(_ p: TSDPoint, path: PathData) -> Bool {
        var inside = false
        for run in polylines(path, steps: 12) {
            let n = run.count
            var j = n - 1
            for i in 0..<n {
                let a = run[i], b = run[j]
                if (a.y > p.y) != (b.y > p.y) {
                    let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                    if p.x < x { inside.toggle() }
                }
                j = i
            }
        }
        return inside
    }

    // MARK: Bounds

    public static func bounds(of object: DesignObject) -> TSDRect? {
        bounds(of: object.shape)
    }

    public static func bounds(of shape: Shape) -> TSDRect? {
        switch shape {
        case .point(let p):
            return TSDRect(minX: p.x, minY: p.y, maxX: p.x, maxY: p.y)
        case .text(let t):
            return textBounds(t)
        case .group(let kids):
            var r: TSDRect?
            for k in kids {
                guard let b = bounds(of: k) else { continue }
                r = r.map { $0.union(b) } ?? b
            }
            return r
        case .circle(let c, let r):
            return TSDRect(minX: c.x - r, minY: c.y - r, maxX: c.x + r, maxY: c.y + r)
        case .ellipse(let c, let rx, let ry):
            return TSDRect(minX: c.x - rx, minY: c.y - ry, maxX: c.x + rx, maxY: c.y + ry)
        case .rect(let r):
            return r
        default:
            guard let p = path(for: shape) else { return nil }
            // Use flattened points so control points outside the curve don't inflate the box.
            return TSDRect.bounding(polylines(p, steps: 12).flatMap { $0 })
        }
    }

    /// Approximate text extent: average glyph width of 0.55 em, ascent 0.8 em, descent 0.2 em.
    /// Renderer measures real glyphs; this is for layout when no text system is available.
    public static func textBounds(_ t: TextData) -> TSDRect {
        let em = t.renderedSize
        let width = Double(t.string.count) * em * 0.55 * t.scaleX
        return TSDRect(minX: t.origin.x, minY: t.origin.y - 0.2 * em, maxX: t.origin.x + max(width, 0.5), maxY: t.origin.y + 0.8 * em)
    }

    // MARK: Transforms

    public static func transform(_ object: DesignObject, by m: Affine) -> DesignObject {
        var o = object
        o.shape = transform(object.shape, by: m)
        if let p = object.rawCirclePoint {
            let moved = m.apply(p)
            if case .circle(let c, let r) = o.shape, abs(c.distance(to: moved) - r) < 1e-6 {
                o.rawCirclePoint = moved
            } else {
                o.rawCirclePoint = nil
            }
        }
        return o
    }

    public static func transform(_ shape: Shape, by m: Affine) -> Shape {
        switch shape {
        case .path(let p):
            return .path(transform(p, by: m))
        case .line(let a, let b):
            return .line(m.apply(a), m.apply(b))
        case .point(let p):
            return .point(m.apply(p))
        case .group(let kids):
            return .group(kids.map { transform($0, by: m) })
        case .text(var t):
            t.origin = m.apply(t.origin)
            t.rawGlyphPositions = t.rawGlyphPositions?.map { m.apply($0) }
            if m.isAxisAligned, !m.isTranslation {
                t.scaleX *= abs(m.a)
                t.scaleY *= abs(m.d)
                t.rawGlyphPositions = nil
            }
            return .text(t)
        case .rect(let r):
            if m.isAxisAligned {
                return .rect(TSDRect(p1: m.apply(TSDPoint(x: r.minX, y: r.minY)), p2: m.apply(TSDPoint(x: r.maxX, y: r.maxY))))
            }
            return .path(transform(path(for: shape)!, by: m))
        case .circle(let c, let r):
            if m.isAxisAligned {
                let sx = abs(m.a), sy = abs(m.d)
                if abs(sx - sy) < 1e-9 { return .circle(center: m.apply(c), radius: r * sx) }
                return .ellipse(center: m.apply(c), rx: r * sx, ry: r * sy)
            }
            return .path(transform(path(for: shape)!, by: m))
        case .ellipse(let c, let rx, let ry):
            if m.isAxisAligned {
                return .ellipse(center: m.apply(c), rx: rx * abs(m.a), ry: ry * abs(m.d))
            }
            return .path(transform(path(for: shape)!, by: m))
        case .arc(let c, let rx, let ry, let a0, let a1):
            if m.isAxisAligned, m.a > 0, m.d > 0 {
                return .arc(center: m.apply(c), rx: rx * m.a, ry: ry * m.d, startAngle: a0, endAngle: a1)
            }
            return .path(transform(path(for: shape)!, by: m))
        }
    }

    public static func transform(_ p: PathData, by m: Affine) -> PathData {
        PathData(segments: p.segments.map { seg in
            switch seg {
            case .move(let q): return .move(m.apply(q))
            case .line(let q): return .line(m.apply(q))
            case .curve(let c1, let c2, let e): return .curve(m.apply(c1), m.apply(c2), m.apply(e))
            }
        }, isClosed: p.isClosed)
    }
}
