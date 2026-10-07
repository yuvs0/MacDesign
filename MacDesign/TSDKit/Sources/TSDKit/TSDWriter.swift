import Foundation

/// Writes a document as a 2D Design V3 file. Records are laid out exactly as TSDReader
/// reads them; a document read and written without edits is byte-identical.
public enum TSDWriter {

    public static func data(for doc: TSDDocument) throws -> Data {
        if doc.isReadOnly {
            throw TSDError.cannotWrite("This file was opened with the fallback reader and can only be exported.")
        }
        let prefix = doc.prefix.isEmpty ? Template.prefix : doc.prefix
        let middle = doc.middle.isEmpty ? Template.middle : doc.middle
        guard !prefix.isEmpty, !middle.isEmpty else {
            throw TSDError.cannotWrite("The file template is missing from the TSDKit bundle.")
        }

        var w = BinaryWriter()
        w.bytes(prefix)

        // Layer table.
        w.u32(UInt32(doc.layers.count))
        for layer in doc.layers {
            w.bytes([0x01, 0x00, 0x03, 0x00])
            w.cString(layer.name)
            w.cString(layer.name)
            w.u16(UInt16(clamping: layer.index))
            w.bytes(layer.rawFlags.count == 2 ? layer.rawFlags : Data([1, 1]))
            w.zeros(7)
            w.bytes([UInt8](repeating: 0xFF, count: 16))
            w.u8(0)
        }

        w.bytes(middle)

        // Objects.
        var ids = IDAllocator(next: doc.nextFileID)
        w.u32(UInt32(doc.objects.count))
        for o in doc.objects {
            w.bytes(o.prefixBytes)
            writeRecord(&w, o, doc: doc, ids: &ids, inheritedID: nil)
        }
        w.bytes(doc.trailer.isEmpty ? TSDDocument.standardTrailer : doc.trailer)
        return w.data
    }

    struct IDAllocator {
        var next: UInt16
        mutating func take() -> UInt16 {
            let v = next
            next &+= 1
            if next == 0 { next = 1 }
            return v
        }
    }

    // MARK: Header

    static func styleBlock(for o: DesignObject) -> Data {
        if let raw = o.rawStyle, raw.count == Record.styleLength, o.loadedStyle == o.style {
            return raw
        }
        return styleBlock(stroke: o.style.strokeColor, fill: o.style.fillColor)
    }

    static func styleBlock(stroke: RGB?, fill: RGB?) -> Data {
        guard stroke != nil || fill != nil else { return Data() }
        var w = BinaryWriter()
        w.bytes([0x01, 0x00])
        w.u32((stroke ?? .black).colorref)
        w.u32((fill ?? .black).colorref)
        w.u32(fill == nil ? 0 : 1)
        w.bytes([0x01, 0x00, 0x00])
        return w.data
    }

    static func writeHeader(_ w: inout BinaryWriter, kind: UInt16, fileID: UInt16, hdr12: Data?, layer: Int, firstLayer: Int, style: Data) {
        w.u16(kind)
        w.bytes(Record.tagObject)
        w.u16(fileID)
        w.zeros(6)
        w.bytes(Record.headerFF)
        w.bytes(Record.semicolon)
        w.bytes(Record.semicolon)
        w.bytes(Record.tagObject)
        var h = (hdr12?.count == 12) ? [UInt8](hdr12!) : [UInt8](repeating: 0, count: 12)
        // Layer reference (see FORMAT.md: unverified against 2D Design itself).
        let v = layer == firstLayer ? 0 : layer
        h[0] = UInt8(v & 0xFF)
        h[1] = UInt8((v >> 8) & 0xFF)
        w.bytes(h)
        w.bytes(Record.penTag)
        if style.count == Record.styleLength {
            w.u16(1)
            w.bytes(style)
        } else {
            w.u16(0)
        }
    }

    // MARK: Records

    static func writeRecord(_ w: inout BinaryWriter, _ o: DesignObject, doc: TSDDocument, ids: inout IDAllocator, inheritedID: UInt16?) {
        let firstLayer = doc.layers.first?.index ?? 1
        let fileID = inheritedID ?? (o.fileID == 0 ? ids.take() : o.fileID)
        let style = styleBlock(for: o)

        func header(_ kind: Record.Kind, style: Data) {
            writeHeader(&w, kind: kind.rawValue, fileID: fileID, hdr12: o.rawHeader, layer: o.layer, firstLayer: firstLayer, style: style)
        }

        switch o.shape {
        case .line(let a, let b):
            header(.line, style: style)
            w.bytes([0x01, 0x00])
            w.f64(a.x); w.f64(a.y); w.f64(b.x); w.f64(b.y)

        case .circle(let c, let r):
            header(.circle, style: style)
            w.bytes([0x01, 0x00])
            var p = TSDPoint(x: c.x + r, y: c.y)
            if let raw = o.rawCirclePoint, abs(c.distance(to: raw) - r) < 1e-6 { p = raw }
            w.f64(c.x); w.f64(c.y); w.f64(p.x); w.f64(p.y)
            w.u8(0)

        case .point(let p):
            header(.point, style: style)
            w.f64(p.x); w.f64(p.y)
            w.u8(1)

        case .group(let kids):
            header(.group, style: style)
            w.bytes([0x04, 0x00, 0x00, 0x00, 0x03, 0x00])
            w.u32(UInt32(kids.count))
            for k in kids { writeRecord(&w, k, doc: doc, ids: &ids, inheritedID: fileID) }

        case .text(let t):
            header(.text, style: style)
            writeText(&w, t, object: o, fileID: fileID, firstLayer: firstLayer, style: style)

        case .path, .rect, .ellipse, .arc:
            header(.path, style: style)
            let path = Geometry.path(for: o.shape) ?? PathData(segments: [], isClosed: false)
            writePath(&w, path)
        }
    }

    static func writePath(_ w: inout BinaryWriter, _ path: PathData) {
        var verts: [(TSDPoint, UInt16)] = []
        var start: TSDPoint?
        for seg in path.segments {
            switch seg {
            case .move(let p):
                verts.append((p, 0)); start = p
            case .line(let p):
                verts.append((p, 1))
            case .curve(let c1, let c2, let e):
                verts.append((c1, 2)); verts.append((c2, 2)); verts.append((e, 3))
            }
        }
        if path.isClosed, let s = start, let last = verts.last, !Geometry.near(s, last.0) {
            verts.append((s, 1))
        }
        w.bytes(Record.tagObject)
        w.u32(UInt32(verts.count))
        for (p, flag) in verts {
            w.bytes([0x03, 0x00])
            w.f64(p.x); w.f64(p.y)
            w.u16(flag)
        }
    }

    // MARK: Text

    static func writeText(_ w: inout BinaryWriter, _ t: TextData, object: DesignObject, fileID: UInt16, firstLayer: Int, style: Data) {
        w.bytes([0x04, 0x00, 0x00, 0x00])
        w.cString(t.string)
        w.f64(t.origin.x); w.f64(t.origin.y)
        w.f64(t.scaleX)
        w.bytes([0x00, 0x00])
        w.f64(t.scaleY)
        w.f64(t.anchor.x); w.f64(t.anchor.y)
        w.u8(0)

        let logFont = t.rawLogFont?.count == Record.logFontLength ? t.rawLogFont! : makeLogFont(t)
        let tail = t.rawFontTail?.count == Record.fontTailLength ? t.rawFontTail! : makeFontTail(t)
        let fontStyle = t.rawFontStyle ?? style
        let glyphStyle = t.rawGlyphStyle ?? style

        // Font sub-record.
        writeHeader(&w, kind: Record.Kind.font.rawValue, fileID: fileID, hdr12: object.rawHeader, layer: object.layer, firstLayer: firstLayer, style: fontStyle)
        writeGlyphBody(&w, char: 0, position: .zero, logFont: logFont, tail: tail)

        // One glyph record per non-space character, each at its pen position.
        let glyphs = t.string.utf16.filter { $0 != 0x20 }
        var positions: [TSDPoint]
        if let raw = t.rawGlyphPositions, raw.count == glyphs.count {
            positions = raw
        } else {
            positions = TextLayout.glyphOrigins(for: t)
            if positions.count != glyphs.count { positions = [TSDPoint](repeating: t.origin, count: glyphs.count) }
        }
        w.bytes([0x03, 0x00])
        w.u32(UInt32(glyphs.count))
        for (ch, pos) in zip(glyphs, positions) {
            writeHeader(&w, kind: Record.Kind.glyph.rawValue, fileID: fileID, hdr12: object.rawHeader, layer: object.layer, firstLayer: firstLayer, style: glyphStyle)
            writeGlyphBody(&w, char: ch, position: pos, logFont: logFont, tail: tail)
        }
        w.bytes([0x00, 0x00])
    }

    static func writeGlyphBody(_ w: inout BinaryWriter, char: UInt16, position: TSDPoint, logFont: Data, tail: Data) {
        w.bytes([0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        w.u16(char)
        w.f64(position.x); w.f64(position.y)
        w.bytes([0x02, 0x00])
        w.bytes(logFont)
        w.bytes(tail)
    }

    /// Windows LOGFONTW. 2D Design uses lfHeight -32 for its 5 mm text, so 6.4 units per mm.
    static func makeLogFont(_ t: TextData) -> Data {
        var w = BinaryWriter()
        let height = Int32(-(t.fontSize * 6.4).rounded())
        w.u32(UInt32(bitPattern: height))   // lfHeight
        w.u32(0)                            // lfWidth
        w.u32(0)                            // lfEscapement
        w.u32(0)                            // lfOrientation
        w.u32(t.isBold ? 700 : 400)         // lfWeight
        w.u8(t.isItalic ? 1 : 0)            // lfItalic
        w.u8(0)                             // lfUnderline
        w.u8(0)                             // lfStrikeOut
        w.u8(0)                             // lfCharSet
        w.u8(3)                             // lfOutPrecision
        w.u8(2)                             // lfClipPrecision
        w.u8(1)                             // lfQuality
        w.u8(0x22)                          // lfPitchAndFamily: variable pitch, swiss
        var units = Array(t.fontFace.utf16.prefix(31))
        units.append(contentsOf: [UInt16](repeating: 0, count: 32 - units.count))
        for u in units { w.u16(u) }
        return w.data
    }

    /// The 90 bytes after the LOGFONT: two metrics, the anchor point and the size.
    static func makeFontTail(_ t: TextData) -> Data {
        var w = BinaryWriter()
        w.bytes([0x00, 0x00])
        w.f64(t.fontSize * 0.893)      // observed: close to the font's ascent in mm
        w.f64(t.fontSize * 0.0895)     // observed: close to the descent in mm
        w.zeros(12)
        w.f64(t.anchor.x); w.f64(t.anchor.y)
        w.zeros(28)
        w.f64(t.fontSize); w.f64(-t.fontSize)
        return w.data
    }
}
