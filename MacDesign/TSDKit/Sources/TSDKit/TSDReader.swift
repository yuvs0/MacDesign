import Foundation

/// Record layout shared by the reader and writer. See docs/FORMAT.md.
enum Record {
    static let signature = "tsdtdv3"

    /// Starts every object header (after the record type, which typeless records omit).
    static let schema: [UInt8] = [0x03, 0x00]
    /// Starts a path's vertex list.
    static let pathTag: [UInt8] = [0x03, 0x00, 0x01, 0x00]
    static let semicolon: [UInt8] = [0xFF, 0xFE, 0xFF, 0x01, 0x3B, 0x00]
    static let lineTag: [UInt8] = [0x03, 0x00]
    static let fillTag: [UInt8] = [0x05, 0x00]
    static let groupTag: [UInt8] = [0x04, 0x00, 0x00, 0x00, 0x03, 0x00]
    static let layerEntryStart: [UInt8] = [0x01, 0x00, 0x03, 0x00, 0xFF, 0xFE, 0xFF]
    /// The settings area between the layer table and the objects always starts with this.
    static let middleStart: [UInt8] = [0x02, 0x00, 0x00, 0x01, 0x01, 0x00, 0x0E, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00]
    /// ...and ends with this, just before the object count.
    static let middleEnd: [UInt8] = [0x19, 0x00, 0x09, 0x00, 0x00, 0x00, 0x03, 0x00]
    /// The 14 header bytes after the object number in every file seen.
    static let headerTail: [UInt8] = [0, 0, 0, 0, 0, 0] + [UInt8](repeating: 0xFF, count: 8)

    enum Kind: UInt16 {
        case font = 0x00
        case point = 0x02
        case line = 0x05
        case circle = 0x06
        case arc = 0x07
        case bezier = 0x08
        case path = 0x09
        case group = 0x0A
        case glyph = 0x0B
        case text = 0x0C
        case dimension = 0x0D
        /// Group-like container; seen holding the tile of a pattern fill.
        case container = 0x0E
        /// A path drawn as two parallel outlines a set width apart.
        case doubleLine = 0x17
    }

    static let logFontLength = 92
    static let fontTailLength = 90
}

/// Structured reader for 2D Design V3 files. Walks the layer table and the object list
/// record by record, so everything it reads can be written back byte for byte.
public enum TSDReader {

    public static func read(url: URL) throws -> TSDDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TSDError.unreadable(error.localizedDescription)
        }
        return try read(data: data)
    }

    public static func read(data: Data) throws -> TSDDocument {
        var r = BinaryReader(data)
        guard let sig = r.cString(at: 0), sig.value == Record.signature else {
            throw TSDError.notA2DDesignFile
        }
        var version = "unknown"
        for o in sig.end..<(sig.end + 16) {
            if let v = r.cString(at: o) { version = v.value; break }
        }

        // Page name from the setup block.
        var pageName: String?
        var pageSize = TSDSize(width: 420, height: 297)
        for o in r.cStringOffsets() {
            if let s = r.cString(at: o), s.value.contains("mm x") {
                pageName = s.value
                let mm = numbersBeforeMM(s.value)
                if mm.count >= 2 { pageSize = TSDSize(width: mm[0], height: mm[1]) }
                break
            }
        }

        // Locate the settings area and the layer table that precedes it.
        guard let middleStart = r.find(Record.middleStart) else {
            throw TSDError.unexpected("settings table", at: 0)
        }
        guard let middleEndStart = r.find(Record.middleEnd, from: middleStart) else {
            throw TSDError.unexpected("object list", at: middleStart)
        }
        let middleEnd = middleEndStart + Record.middleEnd.count

        var layers: [Layer] = []
        var layerListStart: Int?
        var searchFrom = 0
        while let s = r.find(Record.layerEntryStart, from: searchFrom), s < middleStart {
            searchFrom = s + 1
            guard s >= 4, let count = r.u32(s - 4), count >= 1, count <= 64 else { continue }
            var probe = r
            probe.offset = s
            var parsed: [Layer] = []
            var ok = true
            for _ in 0..<count {
                guard let layer = try? readLayer(&probe) else { ok = false; break }
                parsed.append(layer)
            }
            if ok, probe.offset == middleStart {
                layers = parsed
                layerListStart = s - 4
                break
            }
        }
        guard let listStart = layerListStart else {
            throw TSDError.unexpected("layer table", at: middleStart)
        }

        let prefix = Data(r.bytes[0..<listStart])
        let middle = Data(r.bytes[middleStart..<middleEnd])

        r.offset = middleEnd
        let objectCount = try r.readU32()
        var objects: [DesignObject] = []
        for _ in 0..<objectCount {
            var prefixBytes = Data()
            // An unexplained 04 00 precedes point records in the samples.
            if r.peek([0x04, 0x00], at: r.offset), r.peek(Record.schema, at: r.offset + 4) {
                prefixBytes = try r.readBytes(2)
            }
            var o = try readTypedObject(&r)
            o.prefixBytes = prefixBytes
            objects.append(o)
        }
        let trailer = try r.readBytes(r.remaining)

        var doc = TSDDocument(signature: sig.value, version: version, pageName: pageName, pageSize: pageSize,
                              layers: layers, objects: objects, prefix: prefix, middle: middle, trailer: trailer)
        doc.textures = textures(in: prefix)
        return doc
    }

    /// JPEG images in the prefix (the texture table), each preceded by its UInt32 length
    /// and four zero bytes.
    static func textures(in prefix: Data) -> [Data] {
        let r = BinaryReader(prefix)
        var result: [Data] = []
        var from = 0
        while let s = r.find([0xFF, 0xD8, 0xFF], from: from) {
            from = s + 3
            guard s >= 8, let n = r.u32(s - 8), n > 3, s + Int(n) <= r.count,
                  r.peek([0xFF, 0xD9], at: s + Int(n) - 2) else { continue }
            result.append(Data(r.bytes[s..<(s + Int(n))]))
            from = s + Int(n)
        }
        return result
    }

    static func numbersBeforeMM(_ s: String) -> [Double] {
        var result: [Double] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i].isNumber {
                var j = i
                while j < chars.count && (chars[j].isNumber || chars[j] == ".") { j += 1 }
                if j + 1 < chars.count, chars[j] == "m", chars[j + 1] == "m", let v = Double(String(chars[i..<j])) {
                    result.append(v)
                }
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    // MARK: Layers

    static func readLayer(_ r: inout BinaryReader) throws -> Layer {
        try r.expect([0x01, 0x00, 0x03, 0x00], "layer entry")
        let name = try r.readCString()
        let name2 = try r.readCString()
        guard name == name2 else { throw TSDError.unexpected("layer name", at: r.offset) }
        let index = try r.readU16()
        let flags = try r.readBytes(2)
        try r.expect([UInt8](repeating: 0, count: 7), "layer padding")
        try r.expect([UInt8](repeating: 0xFF, count: 16), "layer padding")
        try r.expect([0x00], "layer end")
        return Layer(name: name, index: Int(index), rawFlags: flags)
    }

    // MARK: Records
    //
    // Every object is: [type] header, line block, fill block, body. Objects embedded in
    // another record (a text's font, a dimension's label, an arrow's polyline, the tile of
    // a character pattern) leave out the type, which their parent implies.

    struct Header {
        var layer: UInt16
        var fileID: UInt16
        var tail: Data
        var names: [String]
    }

    static func readHeader(_ r: inout BinaryReader) throws -> Header {
        try r.expect(Record.schema, "object header")
        let layer = try r.readU16()
        let id = try r.readU16()
        let tail = try r.readBytes(14)
        try r.expect([0x00], "object header")
        let n1 = try r.readCString()
        let n2 = try r.readCString()
        return Header(layer: layer, fileID: id, tail: tail, names: [n1, n2])
    }

    struct LineBlock {
        var type: UInt16
        var width: Double
        var color: RGB
        var scale: Double
        var raw: Data
    }

    /// `03 00`, line type, then (type 1) width and colour, or (types 2+) a pattern word and
    /// scale before them. Type 0 is no line.
    static func readLine(_ r: inout BinaryReader) throws -> LineBlock {
        let start = r.offset
        try r.expect(Record.lineTag, "line style")
        let type = try r.readU16()
        var width = 0.0, color: UInt32 = 0, scale = 1.0
        switch type {
        case 0:
            break
        case 1:
            width = try r.readF64()
            color = try r.readU32()
        default:
            _ = try r.readU16()
            scale = try r.readF64()
            width = try r.readF64()
            color = try r.readU32()
        }
        return LineBlock(type: type, width: width, color: RGB(colorref: color), scale: scale,
                         raw: Data(r.bytes[start..<r.offset]))
    }

    static func readF32(_ r: inout BinaryReader) throws -> Double {
        Double(Float(bitPattern: try r.readU32()))
    }

    static func readMatrix(_ r: inout BinaryReader) throws -> [Double] {
        try r.expect([0x01, 0x00], "transform")
        return try (0..<6).map { _ in try r.readF64() }
    }

    /// True where a transform (01 00 + matrix) followed by 01 00 01 00 starts: the end of a
    /// character pattern, whose own layout isn't decoded.
    static func isPatternTail(_ r: BinaryReader, at o: Int) -> Bool {
        guard r.u16(o) == 1, r.peek([0x01, 0x00, 0x01, 0x00], at: o + 50) else { return false }
        var m: [Double] = []
        for k in 0..<6 {
            guard let v = r.f64(o + 2 + 8 * k), v.isFinite, abs(v) < 1e6 else { return false }
            m.append(v)
        }
        return abs(m[0] * m[3] - m[1] * m[2]) > 1e-9
    }

    /// `05 00`, fill type, then a body that depends on the type: 0 none, 1 solid,
    /// 2 hatch, 3 gradient, 4 character pattern, 5 pattern drawn from shapes.
    static func readFill(_ r: inout BinaryReader) throws -> (Fill, Data) {
        let start = r.offset
        try r.expect(Record.fillTag, "fill")
        let type = try r.readU16()
        var fill = Fill.none
        switch type {
        case 0:
            break
        case 1:
            try r.expect([0x01, 0x00], "solid fill")
            let c = try r.readU32()
            _ = try r.readBytes(11)
            fill = .solid(RGB(colorref: c))
        default:
            _ = try r.readU16()
            if try r.readU8() != 0 { _ = try r.readBytes(4) }
            _ = try readMatrix(&r)
            if type == 2 {
                let line = try readLine(&r)
                let scale = try r.readF64(), spacing = try r.readF64(), angle = try r.readF64()
                let flags = try r.readBytes(2)
                let dashes = try r.readU16()
                _ = try r.readBytes(16 * Int(dashes))
                // 40 draws lines 0.5 mm apart in 2D Design.
                fill = .hatch(Hatch(color: line.color, lineWidth: line.width, angle: angle,
                                    spacing: max(0.05, spacing * (scale > 0 ? scale : 1) / 80),
                                    isCrossed: flags.first == 1))
            } else {
                _ = try r.readBytes(15)
                let tileWidth = try r.readF64(), tileHeight = try r.readF64()
                _ = try r.readBytes(32 + 74)
                let tileSize = TSDSize(width: tileWidth > 0 ? tileWidth : 20, height: tileHeight > 0 ? tileHeight : 20)
                let hasBackground = try r.readU8() != 0
                let background = RGB(colorref: try r.readU32())
                switch type {
                case 3:
                    _ = try r.readBytes(6)
                    try r.expect([0x06, 0x00], "gradient")
                    _ = try r.readU8()
                    let n1 = try r.readU16()
                    _ = try r.readBytes(8 * Int(n1))
                    let n2 = try r.readU16()
                    _ = try r.readBytes(8 * Int(n2))
                    let angle = try readF32(&r)
                    let n3 = try r.readU16()
                    var stops: [GradientStop] = []
                    for _ in 0..<n3 {
                        let c = RGB(colorref: try r.readU32())
                        stops.append(GradientStop(color: c, position: try readF32(&r)))
                    }
                    _ = try r.readBytes(17)
                    fill = .gradient(Gradient(stops: stops, angle: angle))
                case 4:
                    _ = try readHeader(&r)
                    _ = try readLine(&r)
                    _ = try readFill(&r)
                    try r.expect([0x06, 0x00], "pattern")
                    let from = r.offset
                    while !isPatternTail(r, at: r.offset) {
                        r.offset += 1
                        if r.offset >= r.count { throw TSDError.unexpected("end of pattern fill", at: from) }
                    }
                    _ = try r.readBytes(50 + 59)
                    fill = .pattern(FillPattern(kind: FillPattern.texture, background: hasBackground ? background : nil, tileSize: tileSize))
                case 5:
                    let tile = try readTypedObject(&r)
                    var shapes = [tile]
                    if case .group(let kids) = tile.shape { shapes = kids }
                    fill = .pattern(FillPattern(kind: FillPattern.drawing, background: hasBackground ? background : nil,
                                                tile: shapes, tileSize: tileSize))
                default:
                    throw TSDError.unexpected("fill type \(type)", at: start)
                }
            }
        }
        return (fill, Data(r.bytes[start..<r.offset]))
    }

    static func style(line: LineBlock, fill: Fill) -> Style {
        var s = Style(strokeColor: line.color, strokeWidth: line.width,
                      lineType: LineType(rawValue: Int(line.type)) ?? .dashed, fill: fill)
        s.dashScale = line.scale
        return s
    }

    static func readTypedObject(_ r: inout BinaryReader) throws -> DesignObject {
        let at = r.offset
        let kind = try r.readU16()
        guard Record.Kind(rawValue: kind) != nil else { throw TSDError.unknownRecordType(kind, at: at) }
        return try readObject(&r, kind: kind)
    }

    static func readObject(_ r: inout BinaryReader, kind: UInt16) throws -> DesignObject {
        let start = r.offset
        let h = try readHeader(&r)
        let line = try readLine(&r)
        let (fill, rawFill) = try readFill(&r)
        var object = DesignObject(fileID: h.fileID, layer: Int(h.layer), style: style(line: line, fill: fill),
                                  shape: .point(.zero), recordType: kind, rawHeader: h.tail)
        object.rawNames = h.names
        object.rawStyle = line.raw
        object.rawFill = rawFill
        object.loadedStyle = object.style

        let bodyStart = r.offset
        guard let k = Record.Kind(rawValue: kind) else { throw TSDError.unknownRecordType(kind, at: start) }
        switch k {
        case .path:
            try r.expect(Record.pathTag, "path")
            let n = try r.readU32()
            var segments: [PathSegment] = []
            var controls: [TSDPoint] = []
            var first: TSDPoint?
            var last: TSDPoint?
            for i in 0..<n {
                try r.expect([0x03, 0x00], "vertex")
                let p = try readPoint(&r)
                let flag = try r.readU16()
                if i == 0 || flag == 0 {
                    segments.append(.move(p)); controls.removeAll()
                    if first == nil { first = p }
                } else if flag == 2 {
                    controls.append(p)
                } else if flag == 3, controls.count >= 2 {
                    segments.append(.curve(controls[controls.count - 2], controls[controls.count - 1], p))
                    controls.removeAll()
                } else {
                    segments.append(.line(p)); controls.removeAll()
                }
                last = p
            }
            let closed = n >= 3 && first != nil && last != nil && Geometry.near(first!, last!)
            object.shape = Geometry.recognise(PathData(segments: segments, isClosed: closed))

        case .line:
            try r.expect([0x01, 0x00], "line")
            object.shape = .line(try readPoint(&r), try readPoint(&r))

        case .circle:
            try r.expect([0x01, 0x00], "circle")
            let c = try readPoint(&r)
            let p = try readPoint(&r)
            _ = try r.readU8()
            object.shape = .circle(center: c, radius: c.distance(to: p))
            object.rawCirclePoint = p

        case .arc:
            // Centre, start and end point, then a direction byte (1 clockwise) and two more.
            try r.expect([0x01, 0x00], "arc")
            let c = try readPoint(&r), p1 = try readPoint(&r), p2 = try readPoint(&r)
            let tail = try r.readBytes(3)
            let radius = c.distance(to: p1)
            var a0 = atan2(p1.y - c.y, p1.x - c.x) * 180 / .pi
            var a1 = atan2(p2.y - c.y, p2.x - c.x) * 180 / .pi
            if tail.first == 1 { swap(&a0, &a1) }
            object.shape = .arc(center: c, rx: radius, ry: radius, startAngle: a0, endAngle: a1)

        case .bezier:
            try r.expect([0x01, 0x00], "curve")
            _ = try r.readU16()
            let degree = Int(try r.readU16())
            var pts: [TSDPoint] = []
            for _ in 0...degree { pts.append(try readPoint(&r)) }
            var segments: [PathSegment] = [.move(pts[0])]
            if degree % 3 == 0 {
                var i = 1
                while i + 2 < pts.count { segments.append(.curve(pts[i], pts[i + 1], pts[i + 2])); i += 3 }
            } else {
                for p in pts.dropFirst() { segments.append(.line(p)) }
            }
            object.shape = .path(PathData(segments: segments, isClosed: false))

        case .point:
            let p = try readPoint(&r)
            _ = try r.readU8()
            object.shape = .point(p)

        case .group:
            try r.expect(Record.groupTag, "group")
            object.shape = .group(try readChildren(&r))

        case .container:
            try r.expect([0x04, 0x00, 0x00, 0x00], "container")
            _ = try r.readBytes(3)
            try r.expect(Record.schema, "container")
            object.shape = .group(try readChildren(&r))

        case .text:
            object.shape = .text(try readTextBody(&r))

        case .dimension:
            object.shape = .group(try readDimension(&r, style: object.style))

        case .doubleLine:
            object.shape = .group(try readDoubleLine(&r, style: object.style))

        case .font, .glyph:
            throw TSDError.unexpected("object", at: start)
        }
        object.rawBody = RawBody(data: Data(r.bytes[bodyStart..<r.offset]), shape: object.shape,
                                 layer: object.layer, fileID: object.fileID, style: object.style)
        return object
    }

    static func readPoint(_ r: inout BinaryReader) throws -> TSDPoint {
        TSDPoint(x: try r.readF64(), y: try r.readF64())
    }

    static func readChildren(_ r: inout BinaryReader) throws -> [DesignObject] {
        let n = try r.readU32()
        var kids: [DesignObject] = []
        for _ in 0..<n { kids.append(try readTypedObject(&r)) }
        return kids
    }

    // MARK: Text

    static func readTextBody(_ r: inout BinaryReader) throws -> TextData {
        try r.expect([0x04, 0x00, 0x00, 0x00], "text")
        let string = try r.readCString()
        let origin = try readPoint(&r)
        let sx = try r.readF64()
        try r.expect([0x00, 0x00], "text")
        let sy = try r.readF64()
        let anchor = try readPoint(&r)
        let flags = try r.readBytes(3)

        // Font: an untyped glyph record holding the LOGFONT.
        _ = try readHeader(&r)
        let fontLine = try readLine(&r)
        let fontFill = try readFill(&r)
        let fontBody = try readGlyphBody(&r)

        try r.expect([0x03, 0x00], "glyph list")
        let glyphCount = try r.readU32()
        var glyphStyle: Data?
        var glyphPositions: [TSDPoint] = []
        for _ in 0..<glyphCount {
            let at = r.offset
            guard try r.readU16() == Record.Kind.glyph.rawValue else { throw TSDError.unexpected("glyph record", at: at) }
            _ = try readHeader(&r)
            let gl = try readLine(&r)
            let gf = try readFill(&r)
            if glyphStyle == nil { glyphStyle = gl.raw + gf.1 }
            glyphPositions.append(try readGlyphBody(&r).position)
        }
        try r.expect([0x00, 0x00], "text terminator")

        let lf = [UInt8](fontBody.logFont)
        var face = ""
        var k = 28
        while k + 1 < lf.count {
            let u = UInt16(lf[k]) | (UInt16(lf[k + 1]) << 8)
            if u == 0 { break }
            face.unicodeScalars.append(Unicode.Scalar(u).map { $0 } ?? "?")
            k += 2
        }
        let weight = Int(lf[16]) | (Int(lf[17]) << 8)
        // Text height (capitals) is the first double of the tail; the one near the end is 5
        // in every file and isn't the size.
        var size = 5.0
        let tailReader = BinaryReader(fontBody.tail)
        if let s = tailReader.f64(2), s.isFinite, s > 0.05, s < 1000 { size = s }
        else if let s = tailReader.f64(74), s.isFinite, s > 0.1, s < 1000 { size = s }
        var t = TextData(string: string, origin: origin, fontFace: face.isEmpty ? "Arial" : face, fontSize: size,
                         scaleX: sx, scaleY: sy, anchor: anchor,
                         isBold: weight >= 600, isItalic: lf[20] != 0,
                         rawLogFont: fontBody.logFont, rawFontTail: fontBody.tail)
        t.rawFontStyle = fontLine.raw + fontFill.1
        t.rawGlyphStyle = glyphStyle
        t.rawGlyphPositions = glyphPositions
        t.rawFlags = flags
        return t
    }

    struct GlyphBody {
        var char: UInt16
        var position: TSDPoint
        var logFont: Data
        var tail: Data
    }

    static func readGlyphBody(_ r: inout BinaryReader) throws -> GlyphBody {
        try r.expect([0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], "glyph")
        let ch = try r.readU16()
        let p = try readPoint(&r)
        try r.expect([0x02, 0x00], "font")
        let lf = try r.readBytes(Record.logFontLength)
        let tail = try r.readBytes(Record.fontTailLength)
        return GlyphBody(char: ch, position: p, logFont: lf, tail: tail)
    }

    // MARK: Dimensions and double lines
    //
    // Both are kept verbatim for saving. For display they are expanded into ordinary shapes;
    // once edited they are saved as a group of those shapes.

    /// Linear dimension: the two measured points, a point the dimension line passes
    /// through, sizes, the "Ø" and "R" prefixes, then the label as an untyped text record.
    static func readDimension(_ r: inout BinaryReader, style: Style) throws -> [DesignObject] {
        try r.expect([0x05, 0x00], "dimension")
        _ = try r.readBytes(7)
        let p1 = try readPoint(&r), p2 = try readPoint(&r), p3 = try readPoint(&r)
        let sizes = try (0..<6).map { _ in try r.readF64() }   // 4, 20, 2, 10, 0, 0 in the test file
        _ = try r.readBytes(3 + 16 + 1)
        _ = try r.readCString()
        _ = try r.readCString()
        _ = try r.readBytes(10)

        let label = try readHeader(&r)
        let labelLine = try readLine(&r)
        let (labelFill, _) = try readFill(&r)
        let text = try readTextBody(&r)
        var labelObject = DesignObject(fileID: label.fileID, layer: Int(label.layer),
                                       style: Self.style(line: labelLine, fill: labelFill), shape: .text(text))
        labelObject.rawNames = label.names

        // Dimension line through p3, parallel to p1-p2, with extension lines and arrowheads.
        let dx = p2.x - p1.x, dy = p2.y - p1.y
        let len = max((dx * dx + dy * dy).squareRoot(), 1e-9)
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let offset = (p3.x - p1.x) * nx + (p3.y - p1.y) * ny
        let side: Double = offset < 0 ? -1 : 1
        let q1 = TSDPoint(x: p1.x + nx * offset, y: p1.y + ny * offset)
        let q2 = TSDPoint(x: p2.x + nx * offset, y: p2.y + ny * offset)
        let overshoot = sizes.count > 2 ? sizes[2] : 2
        var line = style
        line.fill = .none
        func ext(_ p: TSDPoint, _ q: TSDPoint) -> DesignObject {
            DesignObject(layer: labelObject.layer, style: line,
                         shape: .line(p, TSDPoint(x: q.x + nx * side * overshoot, y: q.y + ny * side * overshoot)))
        }
        let parts: [DesignObject] = [
            ext(p1, q1), ext(p2, q2),
            DesignObject(layer: labelObject.layer, style: line, shape: .line(q1, q2)),
            arrowHead(tip: q1, from: q2, length: 3, width: 1.2, style: style, layer: labelObject.layer),
            arrowHead(tip: q2, from: q1, length: 3, width: 1.2, style: style, layer: labelObject.layer),
            labelObject,
        ]
        return parts
    }

    /// Double line: widths, then the centre line as an untyped group of lines. 2D Design
    /// draws only the two outlines, `width` apart, joined by square ends.
    static func readDoubleLine(_ r: inout BinaryReader, style: Style) throws -> [DesignObject] {
        let start = r.offset
        try r.expect([0x01, 0x00], "double line")
        _ = try r.readBytes(49)
        let width = BinaryReader(Data(r.bytes[start..<r.offset])).f64(4) ?? 5

        let centre = try readHeader(&r)
        _ = try readLine(&r)
        _ = try readFill(&r)
        try r.expect(Record.groupTag, "double line")
        let lines = try readChildren(&r)

        var points: [TSDPoint] = []
        for o in lines {
            guard case .line(let a, let b) = o.shape else { continue }
            if points.isEmpty || !Geometry.near(points[points.count - 1], a, 1e-6) { points.append(a) }
            points.append(b)
        }
        var outline = style
        outline.fill = .none
        guard let path = Geometry.doubleLineOutline(points, width: width) else { return lines }
        return [DesignObject(layer: Int(centre.layer), style: outline, shape: .path(path))]
    }

    static func arrowHead(tip: TSDPoint, from: TSDPoint, length: Double, width: Double, style: Style, layer: Int) -> DesignObject {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let d = max((dx * dx + dy * dy).squareRoot(), 1e-9)
        let ux = dx / d, uy = dy / d
        let base = TSDPoint(x: tip.x - ux * length, y: tip.y - uy * length)
        let hw = width / 2
        let a = TSDPoint(x: base.x - uy * hw, y: base.y + ux * hw)
        let b = TSDPoint(x: base.x + uy * hw, y: base.y - ux * hw)
        var s = style
        s.fill = .solid(style.effectiveStroke)
        return DesignObject(layer: layer, style: s,
                            shape: .path(PathData(segments: [.move(tip), .line(a), .line(b), .line(tip)], isClosed: true)))
    }
}
