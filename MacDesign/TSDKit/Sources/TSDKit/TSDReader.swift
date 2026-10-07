import Foundation

/// Record layout shared by the reader and writer. See docs/FORMAT.md.
enum Record {
    static let signature = "tsdtdv3"

    static let tagObject: [UInt8] = [0x03, 0x00, 0x01, 0x00]
    static let headerFF: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    static let semicolon: [UInt8] = [0xFF, 0xFE, 0xFF, 0x01, 0x3B, 0x00]
    static let penTag: [UInt8] = [0x05, 0x00]
    static let layerEntryStart: [UInt8] = [0x01, 0x00, 0x03, 0x00, 0xFF, 0xFE, 0xFF]
    /// The settings area between the layer table and the objects always starts with this.
    static let middleStart: [UInt8] = [0x02, 0x00, 0x00, 0x01, 0x01, 0x00, 0x0E, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00]
    /// ...and ends with this, just before the object count.
    static let middleEnd: [UInt8] = [0x19, 0x00, 0x09, 0x00, 0x00, 0x00, 0x03, 0x00]

    enum Kind: UInt16 {
        case font = 0x00
        case point = 0x02
        case line = 0x05
        case circle = 0x06
        case path = 0x09
        case group = 0x0A
        case glyph = 0x0B
        case text = 0x0C
    }

    static let logFontLength = 92
    static let fontTailLength = 90
    static let styleLength = 17
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
            if r.peek([0x04, 0x00], at: r.offset), r.peek(Record.tagObject, at: r.offset + 4) {
                prefixBytes = try r.readBytes(2)
            }
            var o = try readRecord(&r, layers: layers)
            o.prefixBytes = prefixBytes
            objects.append(o)
        }
        let trailer = try r.readBytes(r.remaining)

        return TSDDocument(signature: sig.value, version: version, pageName: pageName, pageSize: pageSize,
                           layers: layers, objects: objects, prefix: prefix, middle: middle, trailer: trailer)
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

    struct Header {
        var kind: UInt16
        var fileID: UInt16
        var hdr12: Data
        var style: Data   // 17 bytes or empty
    }

    static func readHeader(_ r: inout BinaryReader) throws -> Header {
        let start = r.offset
        let kind = try r.readU16()
        try r.expect(Record.tagObject, "object tag")
        let id = try r.readU16()
        try r.expect([UInt8](repeating: 0, count: 6), "header padding")
        try r.expect(Record.headerFF, "header padding")
        try r.expect(Record.semicolon, "separator")
        try r.expect(Record.semicolon, "separator")
        try r.expect(Record.tagObject, "object tag")
        let hdr12 = try r.readBytes(12)
        try r.expect(Record.penTag, "pen tag")
        let hasStyle = try r.readU16()
        var style = Data()
        if hasStyle == 1 {
            style = try r.readBytes(Record.styleLength)
        } else if hasStyle != 0 {
            throw TSDError.unexpected("pen block", at: start)
        }
        return Header(kind: kind, fileID: id, hdr12: hdr12, style: style)
    }

    static func parseStyle(_ block: Data) -> Style {
        guard block.count == Record.styleLength else { return Style() }
        let b = [UInt8](block)
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
        }
        var s = Style(strokeColor: RGB(colorref: u32(2)))
        let fill = u32(6), flags = u32(10)
        if flags & 1 == 1 { s.fillColor = RGB(colorref: fill) }
        return s
    }

    static func layerIndex(from hdr12: Data, layers: [Layer]) -> Int {
        let b = [UInt8](hdr12)
        let v = Int(b[0]) | (Int(b[1]) << 8)
        if v == 0 { return layers.first?.index ?? 1 }
        return layers.contains { $0.index == v } ? v : (layers.first?.index ?? 1)
    }

    static func readRecord(_ r: inout BinaryReader, layers: [Layer]) throws -> DesignObject {
        let start = r.offset
        let h = try readHeader(&r)
        var object = DesignObject(fileID: h.fileID, layer: layerIndex(from: h.hdr12, layers: layers),
                                  style: parseStyle(h.style), shape: .point(.zero),
                                  recordType: h.kind, rawHeader: h.hdr12)
        object.rawStyle = h.style.isEmpty ? nil : h.style
        object.loadedStyle = object.style

        guard let kind = Record.Kind(rawValue: h.kind) else {
            throw TSDError.unknownRecordType(h.kind, at: start)
        }
        switch kind {
        case .path:
            try r.expect(Record.tagObject, "path tag")
            let n = try r.readU32()
            var segments: [PathSegment] = []
            var controls: [TSDPoint] = []
            var first: TSDPoint?
            var last: TSDPoint?
            for i in 0..<n {
                try r.expect([0x03, 0x00], "vertex")
                let p = TSDPoint(x: try r.readF64(), y: try r.readF64())
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
            let a = TSDPoint(x: try r.readF64(), y: try r.readF64())
            let b = TSDPoint(x: try r.readF64(), y: try r.readF64())
            object.shape = .line(a, b)

        case .circle:
            try r.expect([0x01, 0x00], "circle")
            let c = TSDPoint(x: try r.readF64(), y: try r.readF64())
            let p = TSDPoint(x: try r.readF64(), y: try r.readF64())
            try r.expect([0x00], "circle end")
            object.shape = .circle(center: c, radius: c.distance(to: p))
            object.rawCirclePoint = p

        case .point:
            let p = TSDPoint(x: try r.readF64(), y: try r.readF64())
            try r.expect([0x01], "point end")
            object.shape = .point(p)

        case .group:
            try r.expect([0x04, 0x00, 0x00, 0x00, 0x03, 0x00], "group")
            let n = try r.readU32()
            var kids: [DesignObject] = []
            for _ in 0..<n { kids.append(try readRecord(&r, layers: layers)) }
            object.shape = .group(kids)

        case .text:
            try r.expect([0x04, 0x00, 0x00, 0x00], "text")
            let string = try r.readCString()
            let origin = TSDPoint(x: try r.readF64(), y: try r.readF64())
            let sx = try r.readF64()
            try r.expect([0x00, 0x00], "text")
            let sy = try r.readF64()
            let anchor = TSDPoint(x: try r.readF64(), y: try r.readF64())
            try r.expect([0x00], "text end")
            let font = try readHeader(&r)
            guard font.kind == Record.Kind.font.rawValue else { throw TSDError.unexpected("font record", at: r.offset) }
            let fontBody = try readGlyphBody(&r)
            try r.expect([0x03, 0x00], "glyph list")
            let glyphCount = try r.readU32()
            var glyphStyle: Data?
            var glyphPositions: [TSDPoint] = []
            for _ in 0..<glyphCount {
                let g = try readHeader(&r)
                guard g.kind == Record.Kind.glyph.rawValue else { throw TSDError.unexpected("glyph record", at: r.offset) }
                if glyphStyle == nil { glyphStyle = g.style }
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
            let tail = [UInt8](fontBody.tail)
            var size = 5.0
            if let s = BinaryReader(fontBody.tail).f64(74), s.isFinite, s > 0.1, s < 1000 { size = s }
            var t = TextData(string: string, origin: origin, fontFace: face.isEmpty ? "Arial" : face, fontSize: size,
                             scaleX: sx, scaleY: sy, anchor: anchor,
                             isBold: weight >= 600, isItalic: lf[20] != 0,
                             rawLogFont: fontBody.logFont, rawFontTail: Data(tail))
            t.rawFontStyle = font.style
            t.rawGlyphStyle = glyphStyle
            t.rawGlyphPositions = glyphPositions
            object.shape = .text(t)

        case .font, .glyph:
            throw TSDError.unexpected("object", at: start)
        }
        return object
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
        let p = TSDPoint(x: try r.readF64(), y: try r.readF64())
        try r.expect([0x02, 0x00], "font")
        let lf = try r.readBytes(Record.logFontLength)
        let tail = try r.readBytes(Record.fontTailLength)
        return GlyphBody(char: ch, position: p, logFont: lf, tail: tail)
    }
}
