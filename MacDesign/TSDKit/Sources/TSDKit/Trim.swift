import Foundation

/// Intersections between objects, and 2D Design's "delete between intersections": removing the
/// part of a line, arc or path between the two intersections nearest the point clicked.
public enum Trim {
    // MARK: Segment maths

    /// Where segments a1-a2 and b1-b2 cross, as parameters along each (0...1), or nil.
    public static func intersect(_ a1: TSDPoint, _ a2: TSDPoint, _ b1: TSDPoint, _ b2: TSDPoint) -> (t: Double, u: Double)? {
        let rx = a2.x - a1.x, ry = a2.y - a1.y
        let sx = b2.x - b1.x, sy = b2.y - b1.y
        let denom = rx * sy - ry * sx
        guard abs(denom) > 1e-12 else { return nil }
        let qx = b1.x - a1.x, qy = b1.y - a1.y
        let t = (qx * sy - qy * sx) / denom
        let u = (qx * ry - qy * rx) / denom
        let eps = 1e-9
        guard t >= -eps, t <= 1 + eps, u >= -eps, u <= 1 + eps else { return nil }
        return (min(1, max(0, t)), min(1, max(0, u)))
    }

    static func bezier(_ p0: TSDPoint, _ c1: TSDPoint, _ c2: TSDPoint, _ p3: TSDPoint, _ t: Double) -> TSDPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return TSDPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x, y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
    }

    static func lerp(_ a: TSDPoint, _ b: TSDPoint, _ t: Double) -> TSDPoint {
        TSDPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// De Casteljau split at t: the two halves, each as (p0, c1, c2, p3).
    static func split(_ p0: TSDPoint, _ c1: TSDPoint, _ c2: TSDPoint, _ p3: TSDPoint, at t: Double)
        -> (left: (TSDPoint, TSDPoint, TSDPoint, TSDPoint), right: (TSDPoint, TSDPoint, TSDPoint, TSDPoint)) {
        let a = lerp(p0, c1, t), b = lerp(c1, c2, t), c = lerp(c2, p3, t)
        let d = lerp(a, b, t), e = lerp(b, c, t)
        let m = lerp(d, e, t)
        return ((p0, a, d, m), (m, e, c, p3))
    }

    /// The part of a curve between parameters ta < tb.
    static func subCurve(_ p0: TSDPoint, _ c1: TSDPoint, _ c2: TSDPoint, _ p3: TSDPoint, from ta: Double, to tb: Double)
        -> (TSDPoint, TSDPoint, TSDPoint, TSDPoint) {
        let right = ta <= 0 ? (p0, c1, c2, p3) : split(p0, c1, c2, p3, at: ta).right
        guard tb < 1 else { return right }
        let t2 = (tb - ta) / (1 - ta)
        return split(right.0, right.1, right.2, right.3, at: t2).left
    }

    // MARK: Flattened pieces with parameters

    /// A straight piece of a flattened chain. The key of a point along the chain is
    /// `seg + t`, so keys run from 0 at the chain's start to `segments.count` at its end.
    struct Piece {
        var a: TSDPoint
        var b: TSDPoint
        var seg: Int
        var t0: Double
        var t1: Double

        func key(at t: Double) -> Double { Double(seg) + t0 + (t1 - t0) * t }
        var bounds: TSDRect { TSDRect(p1: a, p2: b) }
    }

    static func pieces(of chain: PathOps.Chain, steps: Int = 16) -> [Piece] {
        var out: [Piece] = []
        var from = chain.start
        for (i, s) in chain.segments.enumerated() {
            switch s {
            case .move(let p):
                from = p
            case .line(let p):
                out.append(Piece(a: from, b: p, seg: i, t0: 0, t1: 1))
                from = p
            case .curve(let c1, let c2, let e):
                var prev = from
                for k in 1...steps {
                    let t = Double(k) / Double(steps)
                    let q = bezier(from, c1, c2, e, t)
                    out.append(Piece(a: prev, b: q, seg: i, t0: Double(k - 1) / Double(steps), t1: t))
                    prev = q
                }
                from = e
            }
        }
        return out
    }

    /// Every chain of an object, groups included.
    static func chains(of object: DesignObject) -> [PathOps.Chain] {
        if case .group(let kids) = object.shape { return kids.flatMap { chains(of: $0) } }
        guard let path = Geometry.path(for: object.shape) else { return [] }
        return PathOps.chains(of: path)
    }

    /// Parameter of the point on a piece nearest p, and the distance.
    static func nearest(on piece: Piece, to p: TSDPoint) -> (t: Double, distance: Double) {
        let dx = piece.b.x - piece.a.x, dy = piece.b.y - piece.a.y
        let len2 = dx * dx + dy * dy
        var t = 0.0
        if len2 > 0 { t = max(0, min(1, ((p.x - piece.a.x) * dx + (p.y - piece.a.y) * dy) / len2)) }
        let q = TSDPoint(x: piece.a.x + t * dx, y: piece.a.y + t * dy)
        return (t, p.distance(to: q))
    }

    // MARK: Intersections near a point (for Attach)

    /// Points where objects cross each other, or themselves, within `tolerance` of p.
    public static func intersections(near p: TSDPoint, tolerance: Double, objects: [DesignObject]) -> [TSDPoint] {
        let box = TSDRect(minX: p.x - tolerance, minY: p.y - tolerance, maxX: p.x + tolerance, maxY: p.y + tolerance)
        // Pieces near the point, tagged by object and chain.
        var near: [(piece: Piece, object: Int, chain: Int)] = []
        for (oi, o) in objects.enumerated() {
            guard let b = Geometry.bounds(of: o), b.insetBy(-tolerance).intersects(box) else { continue }
            for (ci, chain) in chains(of: o).enumerated() {
                for piece in pieces(of: chain) where piece.bounds.insetBy(-tolerance).intersects(box) {
                    near.append((piece, oi, ci))
                }
            }
        }
        var found: [TSDPoint] = []
        for i in 0..<near.count {
            for j in (i + 1)..<near.count {
                let x = near[i], y = near[j]
                if x.object == y.object, x.chain == y.chain {
                    // Same chain: only pieces that don't already share an end can cross.
                    if x.piece.seg == y.piece.seg || abs(x.piece.key(at: 1) - y.piece.key(at: 0)) < 1e-9 || abs(y.piece.key(at: 1) - x.piece.key(at: 0)) < 1e-9 { continue }
                }
                guard let hit = intersect(x.piece.a, x.piece.b, y.piece.a, y.piece.b) else { continue }
                let q = lerp(x.piece.a, x.piece.b, hit.t)
                if q.distance(to: p) <= tolerance, !found.contains(where: { $0.distance(to: q) < 1e-6 }) { found.append(q) }
            }
        }
        return found
    }

    // MARK: Delete between intersections

    /// Removes the part of `object` between the two intersections nearest `p`, counting crossings
    /// with `others` and with itself. With no intersection on one side the object is trimmed to its
    /// end; with none at all, or for a closed shape crossed only once, the whole object goes.
    /// Returns the shapes that remain (possibly none), or nil when the object can't be trimmed.
    public static func deleteBetweenIntersections(of object: DesignObject, at p: TSDPoint, others: [DesignObject]) -> [Shape]? {
        switch object.shape {
        case .group(let kids):
            // Trim the member nearest the point; the others stay and also act as cutters.
            var best: (Int, Double)?
            for (i, k) in kids.enumerated() {
                guard let path = Geometry.path(for: k.shape) else { continue }
                let d = Geometry.distance(from: p, to: path)
                if best == nil || d < best!.1 { best = (i, d) }
            }
            guard let (index, _) = best else { return nil }
            let siblings = kids.enumerated().filter { $0.offset != index }.map { $0.element }
            guard let shapes = deleteBetweenIntersections(of: kids[index], at: p, others: others + siblings) else { return nil }
            var newKids = siblings
            for shape in shapes {
                var k = kids[index]
                k.id = UUID()
                k.shape = shape
                k.recordType = nil
                k.rawCirclePoint = nil
                newKids.insert(k, at: min(index, newKids.count))
            }
            return newKids.isEmpty ? [] : [.group(newKids)]
        case .text, .point: return nil
        default: break
        }
        guard let path = Geometry.path(for: object.shape) else { return nil }
        let chainList = PathOps.chains(of: path)
        guard !chainList.isEmpty else { return nil }
        let pieceLists = chainList.map { pieces(of: $0) }

        // The chain and key the click is nearest to.
        var bestChain = 0, bestKey = 0.0, bestDist = Double.infinity
        for (ci, ps) in pieceLists.enumerated() {
            for piece in ps {
                let n = nearest(on: piece, to: p)
                if n.distance < bestDist { bestDist = n.distance; bestChain = ci; bestKey = piece.key(at: n.t) }
            }
        }
        let chain = chainList[bestChain]
        let ownPieces = pieceLists[bestChain]
        let closed = chain.isClosed
        let count = Double(chain.segments.count)

        // Everything that can cut this chain: other objects, the object's other chains, and itself.
        var cutters: [Piece] = []
        if let b = Geometry.bounds(of: object) {
            for o in others where o.id != object.id {
                guard let ob = Geometry.bounds(of: o), ob.intersects(b) else { continue }
                for c in chains(of: o) { cutters.append(contentsOf: pieces(of: c)) }
            }
        }
        for (ci, ps) in pieceLists.enumerated() where ci != bestChain { cutters.append(contentsOf: ps) }

        var keys: [Double] = []
        func add(_ k: Double) {
            // Ignore crossings at the chain's own ends: they don't split anything.
            if k < 1e-6 || k > count - 1e-6 { return }
            if !keys.contains(where: { abs($0 - k) < 1e-6 }) { keys.append(k) }
        }
        for piece in ownPieces {
            for c in cutters {
                if let hit = intersect(piece.a, piece.b, c.a, c.b) { add(piece.key(at: hit.t)) }
            }
        }
        for i in 0..<ownPieces.count {
            for j in (i + 2)..<max(i + 2, ownPieces.count) {
                if closed, i == 0, j == ownPieces.count - 1 { continue }
                let x = ownPieces[i], y = ownPieces[j]
                if let hit = intersect(x.a, x.b, y.a, y.b) {
                    add(x.key(at: hit.t)); add(y.key(at: hit.u))
                }
            }
        }
        keys.sort()

        let lower = keys.last(where: { $0 < bestKey })
        let upper = keys.first(where: { $0 > bestKey })
        var remaining: [PathOps.Chain] = []
        if closed {
            guard keys.count >= 2 else { return untouched(chainList, except: bestChain, path: path) }
            let lo = lower ?? keys.last!, up = upper ?? keys.first!
            if up < lo {
                if let c = slice(chain, from: up, to: lo) { remaining.append(c) }
            } else if let c = joined(slice(chain, from: up, to: count), slice(chain, from: 0, to: lo)) {
                remaining.append(c)
            }
        } else {
            guard !keys.isEmpty else { return untouched(chainList, except: bestChain, path: path) }
            if let lo = lower, let c = slice(chain, from: 0, to: lo) { remaining.append(c) }
            if let up = upper, let c = slice(chain, from: up, to: count) { remaining.append(c) }
        }

        var shapes = untouched(chainList, except: bestChain, path: path)
        for c in remaining {
            if case .line = object.shape, c.segments.count == 1 {
                shapes.append(.line(c.start, c.end))
            } else if let arc = arcShape(for: object.shape, keyRange: keyRange(of: c, in: chain)) {
                shapes.append(arc)
            } else {
                shapes.append(.path(c.path))
            }
        }
        return shapes
    }

    /// The chains that weren't clicked, kept together as one path.
    private static func untouched(_ chains: [PathOps.Chain], except index: Int, path: PathData) -> [Shape] {
        let rest = chains.enumerated().filter { $0.offset != index }.map { $0.element }
        guard !rest.isEmpty else { return [] }
        let segments = rest.flatMap { [PathSegment.move($0.start)] + $0.segments }
        return [.path(PathData(segments: segments, isClosed: path.isClosed))]
    }

    /// The part of a chain between two keys, as a chain, or nil if it's empty.
    static func slice(_ chain: PathOps.Chain, from k0: Double, to k1: Double) -> PathOps.Chain? {
        guard k1 - k0 > 1e-9 else { return nil }
        var segs: [PathSegment] = []
        var start: TSDPoint?
        var from = chain.start
        for (i, s) in chain.segments.enumerated() {
            let ta = max(k0 - Double(i), 0), tb = min(k1 - Double(i), 1)
            defer { from = s.endPoint }
            guard tb - ta > 1e-9 else { continue }
            switch s {
            case .move:
                continue
            case .line(let p):
                let a = lerp(from, p, ta), b = lerp(from, p, tb)
                if start == nil { start = a }
                segs.append(.line(b))
            case .curve(let c1, let c2, let e):
                let sub = subCurve(from, c1, c2, e, from: ta, to: tb)
                if start == nil { start = sub.0 }
                segs.append(.curve(sub.1, sub.2, sub.3))
            }
        }
        guard let s = start, !segs.isEmpty else { return nil }
        let out = PathOps.Chain(start: s, segments: segs)
        return out.start.distance(to: out.end) < 1e-9 && segs.count == 1 ? nil : out
    }

    private static func joined(_ a: PathOps.Chain?, _ b: PathOps.Chain?) -> PathOps.Chain? {
        guard let a else { return b }
        guard let b else { return a }
        return PathOps.Chain(start: a.start, segments: a.segments + b.segments)
    }

    /// Key range a sliced chain covers in its parent (for turning arc pieces back into arcs).
    private static func keyRange(of piece: PathOps.Chain, in chain: PathOps.Chain) -> (Double, Double)? {
        let ps = pieces(of: chain)
        func key(_ p: TSDPoint) -> Double? {
            var best: (Double, Double)?
            for piece in ps {
                let n = nearest(on: piece, to: p)
                if best == nil || n.distance < best!.1 { best = (piece.key(at: n.t), n.distance) }
            }
            return best.map { $0.0 }
        }
        guard let a = key(piece.start), let b = key(piece.end) else { return nil }
        return (a, b)
    }

    /// For circles, ellipses and arcs the remaining piece is an arc of the same ellipse.
    private static func arcShape(for shape: Shape, keyRange: (Double, Double)?) -> Shape? {
        guard let (k0, k1) = keyRange else { return nil }
        let c: TSDPoint, rx: Double, ry: Double
        var start: Double, end: Double
        switch shape {
        case .circle(let cc, let r):
            // ellipsePath starts at the top and runs clockwise: key k sits at 90° - 90°k.
            (c, rx, ry) = (cc, r, r)
            (start, end) = (90 - 90 * k1, 90 - 90 * k0)
        case .ellipse(let cc, let x, let y):
            (c, rx, ry) = (cc, x, y)
            (start, end) = (90 - 90 * k1, 90 - 90 * k0)
        case .arc(let cc, let x, let y, let s, let e):
            // arcPath runs anticlockwise from startAngle in equal pieces of at most 90°.
            var sw = e - s
            while sw <= 0 { sw += 360 }
            sw = min(sw, 360)
            let per = sw / Double(max(1, Int(ceil(sw / 90 - 1e-9))))
            (c, rx, ry) = (cc, x, y)
            (start, end) = (s + k0 * per, s + k1 * per)
        default: return nil
        }
        while start < 0 { start += 360; end += 360 }
        while start >= 360 { start -= 360; end -= 360 }
        while end < start { end += 360 }
        guard end - start > 1e-6 else { return nil }
        return .arc(center: c, rx: rx, ry: ry, startAngle: start, endAngle: end)
    }
}
