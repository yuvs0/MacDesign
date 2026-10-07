import Foundation

/// How a filleted corner is rounded.
public enum FilletStyle: Equatable, Sendable {
    /// A circular arc, tangent to both sides (G1).
    case arc
    /// Figma-style corner smoothing: a shorter arc on the same circle, eased into each side
    /// with a cubic so the curvature builds up gradually. `smoothing` is 0...1; Apple's
    /// shapes are close to 0.6.
    case smooth(Double)

    public var smoothing: Double {
        switch self {
        case .arc: return 0
        case .smooth(let s): return min(max(s, 0), 1)
        }
    }
}

/// Rounds the corners of a path.
public enum Fillet {
    /// Corners sharper than this (turn angle in degrees) or straighter than 180° minus this
    /// are left alone: a tangential or collinear join has no corner to round.
    public static let minimumTurn = 2.0

    public struct Result: Equatable {
        public var path: PathData
        /// How many corners were rounded.
        public var count: Int
        /// Why a requested corner was skipped, when all of them were.
        public var reason: String?
    }

    // MARK: Ring form

    /// A path as nodes joined by segments; segment k runs from node k to node k + 1
    /// (wrapping for closed paths).
    struct Ring {
        var nodes: [TSDPoint]
        var segments: [PathSegment]   // one per span; .move never appears
        var isClosed: Bool

        init?(_ path: PathData) {
            var nodes: [TSDPoint] = []
            var segs: [PathSegment] = []
            for (i, s) in path.segments.enumerated() {
                switch s {
                case .move(let p):
                    if i == 0 { nodes = [p] } else { return nil }   // several runs: not supported
                case .line, .curve:
                    if nodes.isEmpty { nodes = [s.endPoint] } else { nodes.append(s.endPoint); segs.append(s) }
                }
            }
            guard segs.count >= 1 else { return nil }
            isClosed = path.isClosed
            if isClosed, nodes.count >= 2, Geometry.near(nodes[0], nodes[nodes.count - 1], 1e-6) {
                nodes.removeLast()
                // The closing segment now runs from the last node back to node 0.
            } else if isClosed {
                segs.append(.line(nodes[0]))
            }
            self.nodes = nodes
            self.segments = segs
        }

        var nodeCount: Int { nodes.count }
        var segmentCount: Int { segments.count }

        func start(of k: Int) -> TSDPoint { nodes[k % nodes.count] }

        /// Interior nodes can be filleted; the ends of an open path can't.
        func canFillet(node k: Int) -> Bool {
            isClosed ? nodeCount >= 3 : (k > 0 && k < nodeCount - 1)
        }

        func incoming(_ k: Int) -> Int { isClosed ? (k + segmentCount - 1) % segmentCount : k - 1 }
        func outgoing(_ k: Int) -> Int { k % segmentCount }
    }

    // MARK: Cubic helpers

    struct Cubic {
        var p0, c1, c2, p3: TSDPoint

        init(from a: TSDPoint, segment: PathSegment) {
            p0 = a
            switch segment {
            case .move(let p), .line(let p):
                c1 = TSDPoint(x: a.x + (p.x - a.x) / 3, y: a.y + (p.y - a.y) / 3)
                c2 = TSDPoint(x: a.x + 2 * (p.x - a.x) / 3, y: a.y + 2 * (p.y - a.y) / 3)
                p3 = p
            case .curve(let a1, let a2, let e):
                c1 = a1; c2 = a2; p3 = e
            }
        }

        init(_ p0: TSDPoint, _ c1: TSDPoint, _ c2: TSDPoint, _ p3: TSDPoint) {
            self.p0 = p0; self.c1 = c1; self.c2 = c2; self.p3 = p3
        }

        func point(_ t: Double) -> TSDPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return TSDPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x, y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
        }

        /// Unit tangent at t, robust to coincident control points.
        func tangent(_ t: Double) -> TSDPoint {
            let u = 1 - t
            var dx = 3 * u * u * (c1.x - p0.x) + 6 * u * t * (c2.x - c1.x) + 3 * t * t * (p3.x - c2.x)
            var dy = 3 * u * u * (c1.y - p0.y) + 6 * u * t * (c2.y - c1.y) + 3 * t * t * (p3.y - c2.y)
            if dx * dx + dy * dy < 1e-18 {
                let q = point(min(max(t + (t < 0.5 ? 1e-3 : -1e-3), 0), 1)), r = point(t)
                dx = t < 0.5 ? q.x - r.x : r.x - q.x
                dy = t < 0.5 ? q.y - r.y : r.y - q.y
            }
            let l = max((dx * dx + dy * dy).squareRoot(), 1e-12)
            return TSDPoint(x: dx / l, y: dy / l)
        }

        func split(at t: Double) -> (Cubic, Cubic) {
            func mid(_ a: TSDPoint, _ b: TSDPoint) -> TSDPoint { TSDPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
            let p01 = mid(p0, c1), p12 = mid(c1, c2), p23 = mid(c2, p3)
            let p012 = mid(p01, p12), p123 = mid(p12, p23)
            let m = mid(p012, p123)
            return (Cubic(p0, p01, p012, m), Cubic(m, p123, p23, p3))
        }

        var length: Double {
            var l = 0.0, prev = p0
            for i in 1...32 { let q = point(Double(i) / 32); l += prev.distance(to: q); prev = q }
            return l
        }

        /// Parameter at arc length `d` from the start (clamped).
        func parameter(atLength d: Double) -> Double {
            var l = 0.0, prev = p0
            for i in 1...64 {
                let t = Double(i) / 64
                let q = point(t)
                let step = prev.distance(to: q)
                if l + step >= d { return (Double(i - 1) + (step > 0 ? (d - l) / step : 0)) / 64 }
                l += step; prev = q
            }
            return 1
        }

        var isStraight: Bool {
            let d = p3.distance(to: p0)
            guard d > 1e-9 else { return true }
            func off(_ q: TSDPoint) -> Double { abs((p3.x - p0.x) * (p0.y - q.y) - (p0.x - q.x) * (p3.y - p0.y)) / d }
            return off(c1) < 1e-6 && off(c2) < 1e-6
        }

        var segment: PathSegment { isStraight ? .line(p3) : .curve(c1, c2, p3) }
    }

    // MARK: Vector helpers

    static func sub(_ a: TSDPoint, _ b: TSDPoint) -> TSDPoint { TSDPoint(x: a.x - b.x, y: a.y - b.y) }
    static func add(_ a: TSDPoint, _ b: TSDPoint, _ k: Double = 1) -> TSDPoint { TSDPoint(x: a.x + b.x * k, y: a.y + b.y * k) }
    static func cross(_ a: TSDPoint, _ b: TSDPoint) -> Double { a.x * b.y - a.y * b.x }
    static func dot(_ a: TSDPoint, _ b: TSDPoint) -> Double { a.x * b.x + a.y * b.y }
    static func rotate(_ v: TSDPoint, _ angle: Double) -> TSDPoint {
        TSDPoint(x: v.x * cos(angle) - v.y * sin(angle), y: v.x * sin(angle) + v.y * cos(angle))
    }

    /// Where the line through `a` along `u` meets the line through `b` along `v`.
    static func intersect(_ a: TSDPoint, _ u: TSDPoint, _ b: TSDPoint, _ v: TSDPoint) -> TSDPoint? {
        let den = cross(u, v)
        guard abs(den) > 1e-12 else { return nil }
        let s = cross(sub(b, a), v) / den
        return add(a, u, s)
    }

    /// Cubics approximating a circular arc from angle a0 sweeping `sweep` (signed) about c.
    static func arcCubics(center c: TSDPoint, radius r: Double, from a0: Double, sweep: Double) -> [Cubic] {
        let pieces = max(1, Int(ceil(abs(sweep) / (.pi / 2) - 1e-9)))
        let step = sweep / Double(pieces)
        let h = 4.0 / 3.0 * tan(abs(step) / 4) * r
        let sign: Double = sweep >= 0 ? 1 : -1
        var out: [Cubic] = []
        var a = a0
        for _ in 0..<pieces {
            let p0 = TSDPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            let p3 = TSDPoint(x: c.x + r * cos(a + step), y: c.y + r * sin(a + step))
            let t0 = TSDPoint(x: -sin(a) * sign, y: cos(a) * sign)
            let t3 = TSDPoint(x: -sin(a + step) * sign, y: cos(a + step) * sign)
            out.append(Cubic(p0, add(p0, t0, h), add(p3, t3, -h), p3))
            a += step
        }
        return out
    }

    // MARK: The corner

    /// The pieces that replace a corner: the virtual corner P (where the two tangents meet),
    /// the cut points on each side, and the cubics joining them.
    struct Corner {
        var cubics: [Cubic]
    }

    /// Builds the fillet between cut point A (tangent u arriving) and cut point B (tangent v
    /// leaving), both at distance `p` from the virtual corner. Returns nil for a straight join.
    static func corner(a: TSDPoint, u: TSDPoint, b: TSDPoint, v: TSDPoint, radius r: Double, style: FilletStyle) -> [Cubic]? {
        let turn = atan2(cross(u, v), dot(u, v))   // signed, -π...π
        let phi = abs(turn)
        guard phi > minimumTurn * .pi / 180, phi < .pi - minimumTurn * .pi / 180, let corner = intersect(a, u, b, v) else { return nil }
        let sign: Double = turn >= 0 ? 1 : -1
        let xi = style.smoothing
        let t = r * tan(phi / 2)                       // tangent length of the plain arc fillet
        // Centre of the fillet circle, on the inside of the turn.
        let a0 = add(corner, u, -t), b0 = add(corner, v, t)
        let inward = rotate(u, sign * .pi / 2)
        let centre = add(a0, inward, r)
        let startAngle = atan2(a0.y - centre.y, a0.x - centre.x)
        if xi <= 0.001 {
            return arcCubics(center: centre, radius: r, from: startAngle, sweep: sign * phi)
        }
        // Smoothing: a shorter arc on the same circle, eased in from further along each side.
        let ease = phi * xi / 2
        let arcSweep = sign * (phi - 2 * ease)
        let a1Angle = startAngle + sign * ease
        let a1 = TSDPoint(x: centre.x + r * cos(a1Angle), y: centre.y + r * sin(a1Angle))
        let tA1 = rotate(u, sign * ease)
        let b1Angle = a1Angle + arcSweep
        let b1 = TSDPoint(x: centre.x + r * cos(b1Angle), y: centre.y + r * sin(b1Angle))
        let tB1 = rotate(v, -sign * ease)
        _ = b0
        var out: [Cubic] = []
        // Side A: from the cut point along u to A1, ending tangent to the circle.
        if let c2 = intersect(a, u, a1, tA1) {
            let along = dot(sub(c2, a), u)
            let c1 = add(a, u, along * 2 / 3)
            out.append(Cubic(a, c1, c2, a1))
        } else {
            out.append(Cubic(a, a, a1, a1))
        }
        out += arcCubics(center: centre, radius: r, from: a1Angle, sweep: arcSweep)
        if let c1 = intersect(b, v, b1, tB1) {
            let along = dot(sub(b, c1), v)
            let c2 = add(b, v, -along * 2 / 3)
            out.append(Cubic(b1, c1, c2, b))
        } else {
            out.append(Cubic(b1, b1, b, b))
        }
        return out
    }

    // MARK: Applying to a path

    /// Rounds the given corners (node indices in ring form; nil means every corner) with
    /// `radius` mm. Corners whose sides are too short get a smaller radius.
    public static func apply(to path: PathData, corners: Set<Int>?, radius: Double, style: FilletStyle) -> Result {
        guard radius > 0, let ring = Ring(path) else {
            return Result(path: path, count: 0, reason: "Only a single run can be filleted.")
        }
        let xi = style.smoothing
        let wanted = corners ?? Set(0..<ring.nodeCount)
        let cubics = ring.segments.enumerated().map { Cubic(from: ring.start(of: $0.offset), segment: $0.element) }
        let lengths = cubics.map { $0.length }

        // Plan each corner: how much to cut from each side and the turn angle.
        struct Plan { var cut: Double; var radius: Double }
        var plans: [Int: Plan] = [:]
        var skipped: String?
        for k in wanted.sorted() where ring.canFillet(node: k) {
            let inn = cubics[ring.incoming(k)], out = cubics[ring.outgoing(k)]
            let u = inn.tangent(1), v = out.tangent(0)
            let turn = abs(atan2(cross(u, v), dot(u, v)))
            if turn <= minimumTurn * .pi / 180 { skipped = "The sides are tangential or collinear, so there is no corner to round."; continue }
            if turn >= .pi - minimumTurn * .pi / 180 { skipped = "The sides fold back on each other."; continue }
            var r = radius
            var cut = (1 + xi) * r * tan(turn / 2)
            let room = 0.49 * min(lengths[ring.incoming(k)], lengths[ring.outgoing(k)])
            if cut > room { cut = room; r = cut / ((1 + xi) * tan(turn / 2)) }
            plans[k] = Plan(cut: cut, radius: r)
        }
        guard !plans.isEmpty else {
            return Result(path: path, count: 0, reason: skipped ?? (wanted.isEmpty ? "No corner selected." : "The ends of an open path can't be rounded."))
        }

        // Cut each segment at both ends, then build the corners between the cut pieces.
        struct Piece { var cubic: Cubic; var startCut: Double; var endCut: Double }
        var pieces: [Piece] = []
        for k in 0..<ring.segmentCount {
            let startNode = k, endNode = ring.isClosed ? (k + 1) % ring.nodeCount : k + 1
            pieces.append(Piece(cubic: cubics[k], startCut: plans[startNode]?.cut ?? 0, endCut: plans[endNode]?.cut ?? 0))
        }
        // Trim: the cut at the end comes off first so the start parameter is measured on the original.
        var trimmed: [Cubic] = []
        for p in pieces {
            var c = p.cubic
            if p.endCut > 0 {
                let t = c.parameter(atLength: max(c.length - p.endCut, 0))
                c = c.split(at: max(t, 1e-6)).0
            }
            if p.startCut > 0 {
                let t = c.parameter(atLength: p.startCut)
                c = c.split(at: min(t, 1 - 1e-6)).1
            }
            trimmed.append(c)
        }

        var out: [PathSegment] = []
        var count = 0
        let first = trimmed[0].p0
        out.append(.move(first))
        for k in 0..<ring.segmentCount {
            out.append(trimmed[k].segment)
            let node = ring.isClosed ? (k + 1) % ring.nodeCount : k + 1
            guard let plan = plans[node], node < ring.nodeCount else { continue }
            let inn = trimmed[k]
            let outSeg = trimmed[(k + 1) % ring.segmentCount]
            if let fillet = corner(a: inn.p3, u: inn.tangent(1), b: outSeg.p0, v: outSeg.tangent(0), radius: plan.radius, style: style) {
                for c in fillet { out.append(c.segment) }
                count += 1
            } else {
                out.append(.line(outSeg.p0))
            }
        }
        if ring.isClosed, let last = out.last, !Geometry.near(last.endPoint, first, 1e-6) {
            out.append(.line(first))
        }
        return Result(path: PathData(segments: out, isClosed: ring.isClosed), count: count,
                      reason: count == 0 ? skipped : nil)
    }

    /// Fillets the corners where two or more objects meet: joins them into one run and
    /// rounds every node that was an end of one of the original pieces.
    public static func joinAndFillet(_ objects: [DesignObject], radius: Double, style: FilletStyle) -> (DesignObject, Result)? {
        guard let template = objects.first else { return nil }
        let chains = objects.flatMap { PathOps.chains(of: $0) }
        let joined = PathOps.join(chains)
        guard joined.count == 1, let run = joined.first else { return nil }
        let ends = chains.flatMap { [$0.start, $0.end] }
        guard let ring = Ring(run.path) else { return nil }
        var corners: Set<Int> = []
        for (i, n) in ring.nodes.enumerated() where ring.canFillet(node: i) && ends.contains(where: { Geometry.near($0, n, PathOps.joinTolerance) }) {
            corners.insert(i)
        }
        let result = apply(to: run.path, corners: corners, radius: radius, style: style)
        var o = DesignObject(layer: template.layer, style: template.style, shape: .path(result.path))
        if !result.path.isClosed { o.style.fill = .none }
        return (o, result)
    }
}
