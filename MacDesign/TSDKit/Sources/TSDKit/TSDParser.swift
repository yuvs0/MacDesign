import Foundation

/// Entry point for reading files. Uses the structured reader, and falls back to a
/// pattern scanner (read-only, export-only) when a file contains records we don't know yet.
public enum TSDParser {

    public static func parse(url: URL) throws -> TSDDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TSDError.unreadable(error.localizedDescription)
        }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> TSDDocument {
        do {
            return try TSDReader.read(data: data)
        } catch TSDError.notA2DDesignFile {
            throw TSDError.notA2DDesignFile
        } catch {
            var doc = try LegacyScanner.scan(data: data)
            doc.isReadOnly = true
            doc.fallbackReason = error.localizedDescription
            return doc
        }
    }
}

/// Finds paths and text by pattern without understanding the record structure.
/// Only used when TSDReader fails. Everything after the layer table is treated as drawing.
enum LegacyScanner {
    static let settingsStrings: Set<String> = ["", ";", "General HPGL plotter", "PA;PA;", "9100", "1:1"]

    static func scan(data: Data) throws -> TSDDocument {
        let r = BinaryReader(data)
        guard let sig = r.cString(at: 0), sig.value == Record.signature else {
            throw TSDError.notA2DDesignFile
        }
        var doc = TSDDocument()
        doc.layers = [Layer(name: "Layer 1", index: 1)]
        doc.prefix = Data()
        doc.middle = Data()

        // Only look after the layer table, so the hidden template graphic is skipped.
        let from = r.find(Record.middleStart) ?? 0

        for o in r.cStringOffsets() where o > from {
            guard let s = r.cString(at: o) else { continue }
            if s.value.contains("mm x") {
                doc.pageName = s.value
                let mm = TSDReader.numbersBeforeMM(s.value)
                if mm.count >= 2 { doc.pageSize = TSDSize(width: mm[0], height: mm[1]) }
            }
        }

        var i = from + 4
        let b = r.bytes
        while i + 20 <= b.count {
            if b[i] == 3, b[i + 1] == 0, let count = r.u32(i - 4), count >= 2, count <= 20_000,
               let (path, end) = readPath(r, start: i, count: Int(count)) {
                doc.objects.append(DesignObject(shape: Geometry.recognise(path)))
                i = end
                continue
            }
            i += 1
        }

        for o in r.cStringOffsets() where o > from {
            guard let s = r.cString(at: o), !settingsStrings.contains(s.value),
                  !s.value.contains("mm x"), !s.value.hasPrefix("Layer"),
                  s.value.unicodeScalars.allSatisfy({ $0.value >= 0x20 }),
                  r.peek([0x04, 0x00, 0x00, 0x00], at: o - 4),
                  let x = r.f64(s.end), let y = r.f64(s.end + 8), x.isFinite, y.isFinite,
                  abs(x) < 5000, abs(y) < 5000 else { continue }
            doc.objects.append(DesignObject(shape: .text(TextData(string: s.value, origin: TSDPoint(x: x, y: y)))))
        }
        return doc
    }

    static func readPath(_ r: BinaryReader, start: Int, count: Int) -> (PathData, Int)? {
        var segments: [PathSegment] = []
        var controls: [TSDPoint] = []
        var first: TSDPoint?, last: TSDPoint?
        var j = start
        for i in 0..<count {
            guard r.u8(j) == 3, r.u8(j + 1) == 0,
                  let x = r.f64(j + 2), let y = r.f64(j + 10), let flag = r.u16(j + 18),
                  x.isFinite, y.isFinite, abs(x) < 5000, abs(y) < 5000, flag <= 3
            else { return nil }
            let p = TSDPoint(x: x, y: y)
            if i == 0 || flag == 0 {
                segments.append(.move(p)); controls.removeAll(); if first == nil { first = p }
            } else if flag == 2 {
                controls.append(p)
            } else if flag == 3, controls.count >= 2 {
                segments.append(.curve(controls[controls.count - 2], controls[controls.count - 1], p)); controls.removeAll()
            } else {
                segments.append(.line(p)); controls.removeAll()
            }
            last = p
            j += 20
        }
        let closed = count >= 3 && first != nil && last != nil && Geometry.near(first!, last!)
        return (PathData(segments: segments, isClosed: closed), j)
    }
}
