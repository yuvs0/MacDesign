import Foundation

/// Joining and splitting paths: 2D Design's Make Path and Explode.
public enum PathOps {
    /// Distance within which two end points count as touching, in mm.
    public static let joinTolerance = 0.01

    /// One run of segments starting at `start`; the segments carry their own end points.
    public struct Chain: Equatable {
        public var start: TSDPoint
        public var segments: [PathSegment]

        public var end: TSDPoint { segments.last?.endPoint ?? start }
        public var isClosed: Bool { segments.count >= 2 && Geometry.near(start, end, joinTolerance) }

        public var path: PathData {
            PathData(segments: [.move(start)] + segments, isClosed: isClosed)
        }

        /// The same run traversed the other way.
        public func reversed() -> Chain {
            var out: [PathSegment] = []
            var from = start
            var points: [(PathSegment, TSDPoint)] = []
            for s in segments { points.append((s, from)); from = s.endPoint }
            for (s, origin) in points.reversed() {
                switch s {
                case .move, .line: out.append(.line(origin))
                case .curve(let c1, let c2, _): out.append(.curve(c2, c1, origin))
                }
            }
            return Chain(start: end, segments: out)
        }
    }

    /// Splits a path at every move into chains. A move with nothing after it is dropped.
    public static func chains(of path: PathData) -> [Chain] {
        var result: [Chain] = []
        var current: Chain?
        for seg in path.segments {
            switch seg {
            case .move(let p):
                if let c = current, !c.segments.isEmpty { result.append(c) }
                current = Chain(start: p, segments: [])
            case .line, .curve:
                if current == nil { current = Chain(start: seg.endPoint, segments: []) } else { current!.segments.append(seg) }
            }
        }
        if let c = current, !c.segments.isEmpty { result.append(c) }
        // A closed path whose last point doesn't repeat the first gets the closing line.
        if path.isClosed, var last = result.popLast() {
            if !Geometry.near(last.start, last.end, joinTolerance) { last.segments.append(.line(last.start)) }
            result.append(last)
        }
        return result
    }

    /// Joins chains whose ends touch into as few chains as possible. Chains may be reversed
    /// to fit. Order follows the input: each chain in turn absorbs whatever touches it.
    public static func join(_ input: [Chain]) -> [Chain] {
        var pool = input
        var result: [Chain] = []
        while !pool.isEmpty {
            var chain = pool.removeFirst()
            var grew = true
            while grew, !chain.isClosed {
                grew = false
                for i in pool.indices {
                    let other = pool[i]
                    if Geometry.near(chain.end, other.start, joinTolerance) {
                        chain.segments += other.segments
                    } else if Geometry.near(chain.end, other.end, joinTolerance) {
                        chain.segments += other.reversed().segments
                    } else if Geometry.near(other.end, chain.start, joinTolerance) {
                        chain = Chain(start: other.start, segments: other.segments + chain.segments)
                    } else if Geometry.near(other.start, chain.start, joinTolerance) {
                        let r = other.reversed()
                        chain = Chain(start: r.start, segments: r.segments + chain.segments)
                    } else {
                        continue
                    }
                    pool.remove(at: i)
                    grew = true
                    break
                }
            }
            result.append(chain)
        }
        return result
    }

    /// Every chain in an object: groups are flattened, primitives converted to paths.
    /// Text and points contribute nothing.
    public static func chains(of object: DesignObject) -> [Chain] {
        switch object.shape {
        case .group(let kids): return kids.flatMap { chains(of: $0) }
        case .text, .point: return []
        default: return Geometry.path(for: object.shape).map { chains(of: $0) } ?? []
        }
    }

    /// Make Path: joins everything in `objects` that touches. Returns one path object per
    /// contiguous run, styled like the first object.
    public static func makePath(_ objects: [DesignObject]) -> [DesignObject] {
        guard let first = objects.first else { return [] }
        let joined = join(objects.flatMap { chains(of: $0) })
        return joined.map { chain in
            var o = DesignObject(layer: first.layer, style: first.style, shape: .path(chain.path))
            // Open runs can't be filled.
            if !chain.isClosed { o.style.fill = .none }
            return o
        }
    }

    /// True for things Explode leaves alone: lines, native circles and arcs, text, points,
    /// and a path that is a single segment.
    public static func isPrimitive(_ object: DesignObject) -> Bool {
        switch object.shape {
        case .line, .circle, .arc, .text, .point: return true
        case .group: return false
        case .path(let p): return p.segments.count <= 2
        default: return false
        }
    }

    /// Explode fully: keeps splitting until only primitives remain.
    public static func explodeFully(_ object: DesignObject) -> [DesignObject] {
        if isPrimitive(object) { return [object] }
        let parts = explode(object)
        if parts.count == 1, parts[0].shape == object.shape { return parts }
        return parts.flatMap { explodeFully($0) }
    }

    /// Explode, one level: a group becomes its members; a path with several runs becomes one
    /// object per run; a single run becomes one object per segment. Primitives stay.
    public static func explode(_ object: DesignObject) -> [DesignObject] {
        func part(_ path: PathData) -> DesignObject {
            var o = object
            o.id = UUID()
            o.fileID = 0
            o.recordType = nil
            o.rawBody = nil
            o.rawCirclePoint = nil
            o.name = nil
            if path.segments.count == 2, case .move(let a) = path.segments[0], case .line(let b) = path.segments[1] {
                o.shape = .line(a, b)
            } else {
                o.shape = Geometry.recognise(path)
            }
            if !path.isClosed { o.style.fill = .none }
            return o
        }
        switch object.shape {
        case .group(let kids):
            return kids.map { k in var c = k; c.layer = object.layer; c.fileID = 0; return c }
        case .text, .point, .line, .circle, .arc:
            return [object]
        default:
            let runs = chains(of: object)
            if runs.count > 1 { return runs.map { part($0.path) } }
            guard let run = runs.first, run.segments.count > 1 else { return [object] }
            var from = run.start
            return run.segments.map { seg in
                let piece = PathData(segments: [.move(from), seg], isClosed: false)
                from = seg.endPoint
                return part(piece)
            }
        }
    }
}
