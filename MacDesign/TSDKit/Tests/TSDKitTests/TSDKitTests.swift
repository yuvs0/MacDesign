import XCTest
@testable import TSDKit

final class TSDKitTests: XCTestCase {

    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "3vs", subdirectory: "Fixtures"))
    }

    func testRejectsNonDesignFiles() {
        XCTAssertThrowsError(try TSDParser.parse(data: Data("hello".utf8)))
    }

    func testReadsHeaderPageAndLayers() throws {
        let doc = try TSDReader.read(url: try fixture("clock"))
        XCTAssertEqual(doc.signature, "tsdtdv3")
        XCTAssertEqual(doc.version, "V3.28")
        XCTAssertEqual(doc.pageSize, TSDSize(width: 420, height: 297))
        XCTAssertEqual(doc.layers.map { $0.name }, ["Layer 1", "Layer 2", "Layer 3"])
        XCTAssertEqual(doc.layers.map { $0.index }, [1, 2, 3])
        XCTAssertFalse(doc.isReadOnly)
    }

    func testReadsObjects() throws {
        let doc = try TSDReader.read(url: try fixture("clock"))
        XCTAssertEqual(doc.objects.count, 19)

        // The red 70 x 80 mm rectangle at (180, 90).
        let rect = doc.objects.first { if case .rect = $0.shape { return true } else { return false } }
        let r = try XCTUnwrap(rect)
        if case .rect(let box) = r.shape {
            XCTAssertEqual(box.minX, 180, accuracy: 1e-9)
            XCTAssertEqual(box.maxY, 170, accuracy: 1e-9)
        }
        XCTAssertEqual(r.style.fill, .solid(RGB(r: 0xC6, g: 0, b: 0)))
        XCTAssertEqual(r.style.strokeColor, .black)

        let circles = doc.objects.filter { if case .circle = $0.shape { return true } else { return false } }
        XCTAssertEqual(circles.count, 5)

        let texts = doc.objects.compactMap { o -> TextData? in if case .text(let t) = o.shape { return t } else { return nil } }
        XCTAssertEqual(texts.map { $0.string }, ["alex's clock", "fred is weird"])
        XCTAssertEqual(texts[0].fontFace, "Bauhaus 93")
        XCTAssertEqual(texts[0].fontSize, 4.467, accuracy: 1e-3)   // height of capitals
    }

    func testRoundTripIsByteIdentical() throws {
        for name in ["clock", "features"] {
            try assertRoundTrip(try fixture(name))
        }
    }

    func assertRoundTrip(_ url: URL) throws {
        let original = try Data(contentsOf: url)
        let doc = try TSDReader.read(data: original)
        let written = try TSDWriter.data(for: doc)
        XCTAssertEqual(written.count, original.count)
        if written != original {
            let a = [UInt8](original), b = [UInt8](written)
            var diffs: [String] = []
            var i = 0
            while i < min(a.count, b.count), diffs.count < 6 {
                if a[i] != b[i] {
                    let lo = max(0, i - 8), hi = min(a.count, i + 24)
                    diffs.append(String(format: "@0x%X orig %@ | written %@", i,
                                        a[lo..<hi].map { String(format: "%02x", $0) }.joined(separator: " "),
                                        b[lo..<min(b.count, hi)].map { String(format: "%02x", $0) }.joined(separator: " ")))
                    i += 32
                } else { i += 1 }
            }
            XCTFail("Round trip of \(url.lastPathComponent) differs: " + diffs.joined(separator: "\n"))
        }
    }

    /// features.3vs: a test sheet saved from 2D Design with one feature per shape.
    func testReadsEveryFeature() throws {
        let doc = try TSDReader.read(url: try fixture("features"))
        XCTAssertFalse(doc.isReadOnly)
        XCTAssertEqual(doc.objects.count, 32)

        // Row 1: line styles.
        let row1 = doc.objects[0..<7].map { $0.style }
        XCTAssertEqual(row1.map { $0.lineType }, [.solid, .dotted, .dashed, .longDash, .solid, .solid, .solid])
        XCTAssertEqual(row1[1].dashScale, 1, accuracy: 1e-9)   // 1 mm wavelength
        XCTAssertEqual(row1[4].strokeWidth, 1, accuracy: 1e-9)
        XCTAssertEqual(row1[0].strokeWidth, 0)
        XCTAssertEqual(row1[5].strokeColor, .red)
        XCTAssertEqual(row1[6].strokeColor, RGB(r: 0, g: 255, b: 0))

        // Row 2: fills.
        let fills = doc.objects[7..<14].map { $0.style.fill }
        XCTAssertEqual(fills[0], .none)
        XCTAssertEqual(fills[1], .solid(.red))
        guard case .hatch(let hatch) = fills[2] else { return XCTFail("hatch") }
        XCTAssertEqual(hatch.color, .red)
        XCTAssertEqual(hatch.angle, 45, accuracy: 1e-9)
        XCTAssertEqual(hatch.spacing, 0.5, accuracy: 1e-9)
        guard case .gradient(let gradient) = fills[3] else { return XCTFail("gradient") }
        XCTAssertEqual(gradient.stops.map { $0.color }, [.red, .white])
        XCTAssertEqual(gradient.angle, 0, accuracy: 1e-9)   // left to right
        guard case .pattern(let chars) = fills[4], case .pattern(let tile) = fills[5] else { return XCTFail("patterns") }
        XCTAssertEqual(chars.kind, FillPattern.texture)
        XCTAssertEqual(doc.textures.count, 2)   // gold foil texture, then a smiley preview
        XCTAssertEqual(tile.kind, FillPattern.drawing)
        XCTAssertEqual(tile.tile.count, 12)
        XCTAssertEqual(tile.tileSize, TSDSize(width: 20, height: 20))
        guard case .hatch(let cross) = fills[6] else { return XCTFail("cross hatch") }
        XCTAssertTrue(cross.isCrossed)

        // Layers are in the record header.
        XCTAssertEqual(Set(doc.objects.map { $0.layer }), [1, 2])
        let texts = doc.objects.compactMap { o -> TextData? in if case .text(let t) = o.shape { return t } else { return nil } }
        XCTAssertEqual(texts.map { $0.string }, ["Layer 1", "Layer 2"])
        XCTAssertEqual(texts[0].fontSize, 10, accuracy: 1e-9)
        XCTAssertEqual(doc.objects.first { if case .text(let t) = $0.shape { return t.string == "Layer 2" }; return false }?.layer, 2)

        // Layer 2: native circle and arc, a dimension and a 5 mm double line.
        let kinds = doc.objects.compactMap { $0.recordType }
        XCTAssertTrue(kinds.contains(Record.Kind.arc.rawValue))
        let dimension = try XCTUnwrap(doc.objects.first { $0.recordType == Record.Kind.dimension.rawValue })
        guard case .group(let parts) = dimension.shape else { return XCTFail("dimension parts") }
        XCTAssertTrue(parts.contains { if case .text(let t) = $0.shape { return t.string == "70" }; return false })
        let double = try XCTUnwrap(doc.objects.first { $0.recordType == Record.Kind.doubleLine.rawValue })
        guard case .group(let outline) = double.shape, case .path(let p) = outline.first?.shape else { return XCTFail("double line") }
        XCTAssertEqual(p.allPoints.first?.y ?? 0, 212.5, accuracy: 1e-9)   // 2.5 mm above the 210 centre line
        if case .arc(let c, let r, _, let a0, let a1) = try XCTUnwrap(doc.objects.first { $0.recordType == Record.Kind.arc.rawValue }).shape {
            XCTAssertEqual(c, TSDPoint(x: 45, y: 205)); XCTAssertEqual(r, 5, accuracy: 1e-9)
            XCTAssertEqual(a0, 180, accuracy: 1e-9); XCTAssertEqual(a1, 90, accuracy: 1e-9)
        } else { XCTFail("arc") }
    }

    func testEditedFeaturesStillSave() throws {
        var doc = try TSDReader.read(url: try fixture("features"))
        // Move everything: dimensions and double lines become groups, arcs stay native.
        doc.objects = doc.objects.map { Geometry.transform($0, by: .translation(5, -3)) }
        doc.objects[0].style.lineType = .dashed
        doc.objects[0].style.strokeWidth = 0.5
        doc.objects[1].layer = 3
        let back = try TSDReader.read(data: try TSDWriter.data(for: doc))
        XCTAssertEqual(back.objects.count, 32)
        XCTAssertEqual(back.objects[0].style.lineType, .dashed)
        XCTAssertEqual(back.objects[0].style.strokeWidth, 0.5, accuracy: 1e-9)
        XCTAssertEqual(back.objects[1].layer, 3)
        XCTAssertEqual(back.objects[9].style.fill, doc.objects[9].style.fill)   // hatch kept verbatim
        if case .rect(let r) = back.objects[0].shape { XCTAssertEqual(r.minX, 25, accuracy: 1e-9) } else { XCTFail("rect") }
        let arc = try XCTUnwrap(back.objects.first { $0.recordType == Record.Kind.arc.rawValue })
        if case .arc(let c, _, _, _, _) = arc.shape { XCTAssertEqual(c.x, 50, accuracy: 1e-9) } else { XCTFail("arc") }
    }

    func testEditedDocumentReadsBack() throws {
        var doc = try TSDReader.read(url: try fixture("clock"))
        let count = doc.objects.count
        doc.objects.append(DesignObject(layer: 2, style: Style(strokeColor: .blue, fillColor: .red),
                                        shape: .rect(TSDRect(minX: 10, minY: 10, maxX: 50, maxY: 30))))
        doc.objects.append(DesignObject(style: Style(strokeColor: .red), shape: .circle(center: TSDPoint(x: 100, y: 100), radius: 20)))
        doc.objects.append(DesignObject(shape: .text(TextData(string: "Hello", origin: TSDPoint(x: 20, y: 200), fontFace: "Arial", fontSize: 8))))
        doc.layers.append(Layer(name: "Engrave", index: 4))

        let data = try TSDWriter.data(for: doc)
        let back = try TSDReader.read(data: data)
        XCTAssertEqual(back.objects.count, count + 3)
        XCTAssertEqual(back.layers.count, 4)
        let added = back.objects[count]
        XCTAssertEqual(added.layer, 2)
        XCTAssertEqual(added.style.strokeColor, .blue)
        XCTAssertEqual(added.style.fillColor, .red)
        if case .rect(let r) = added.shape { XCTAssertEqual(r.width, 40, accuracy: 1e-9) } else { XCTFail("rect lost") }
        if case .circle(_, let radius) = back.objects[count + 1].shape { XCTAssertEqual(radius, 20, accuracy: 1e-9) } else { XCTFail("circle lost") }
        if case .text(let t) = back.objects[count + 2].shape {
            XCTAssertEqual(t.string, "Hello"); XCTAssertEqual(t.fontFace, "Arial"); XCTAssertEqual(t.fontSize, 8, accuracy: 1e-9)
        } else { XCTFail("text lost") }
    }

    func testBlankDocumentWrites() throws {
        let doc = TSDDocument.blank()
        XCTAssertFalse(doc.prefix.isEmpty, "template prefix should be bundled")
        let data = try TSDWriter.data(for: doc)
        let back = try TSDReader.read(data: data)
        XCTAssertEqual(back.objects.count, 0)
        XCTAssertEqual(back.layers.count, 3)
    }

    func testGeometryHelpers() {
        let e = Geometry.ellipsePath(center: TSDPoint(x: 0, y: 0), rx: 10, ry: 5)
        XCTAssertEqual(e.segments.count, 5)
        if case .ellipse(let c, let rx, let ry) = Geometry.recognise(e) {
            XCTAssertEqual(c, .zero); XCTAssertEqual(rx, 10, accuracy: 1e-9); XCTAssertEqual(ry, 5, accuracy: 1e-9)
        } else { XCTFail("ellipse not recognised") }

        let arc = Geometry.arcPath(center: .zero, rx: 10, ry: 10, startAngle: 0, endAngle: 90)
        XCTAssertEqual(arc.segments.count, 2)
        let end = arc.segments.last!.endPoint
        XCTAssertEqual(end.x, 0, accuracy: 1e-9); XCTAssertEqual(end.y, 10, accuracy: 1e-9)

        let moved = Geometry.transform(Shape.circle(center: .zero, radius: 2), by: .translation(5, 5))
        if case .circle(let c, _) = moved { XCTAssertEqual(c, TSDPoint(x: 5, y: 5)) } else { XCTFail() }
    }

    func testExportsDoNotCrash() throws {
        let doc = try TSDReader.read(url: try fixture("clock"))
        for format in ExportFormat.allCases {
            XCTAssertFalse(try Exporter.data(for: doc, format: format).isEmpty)
        }
        XCTAssertTrue(SVGExporter.string(for: doc).contains("<circle"))
        XCTAssertTrue(DXFExporter.string(for: doc).contains("CIRCLE"))
        XCTAssertFalse(Renderer.pdfData(for: doc).isEmpty)
    }
}

final class PathOpsTests: XCTestCase {
    func line(_ a: (Double, Double), _ b: (Double, Double)) -> DesignObject {
        DesignObject(shape: .line(TSDPoint(x: a.0, y: a.1), TSDPoint(x: b.0, y: b.1)))
    }

    func testMakePathJoinsTouchingRunsAndKeepsOthersApart() {
        // Three lines forming an open L-Z shape, and four more forming a closed square elsewhere.
        let three = [line((0, 0), (10, 0)), line((10, 10), (10, 0)), line((10, 10), (20, 10))]   // middle one reversed
        let four = [line((50, 50), (60, 50)), line((60, 50), (60, 60)), line((60, 60), (50, 60)), line((50, 60), (50, 50))]
        let parts = PathOps.makePath(three + four)
        XCTAssertEqual(parts.count, 2)
        guard case .path(let a) = parts[0].shape, case .path(let b) = parts[1].shape else { return XCTFail("paths") }
        XCTAssertEqual(a.segments.count, 4)   // move + 3 lines
        XCTAssertFalse(a.isClosed)
        XCTAssertEqual(a.segments.last?.endPoint, TSDPoint(x: 20, y: 10))
        XCTAssertEqual(b.segments.count, 5)
        XCTAssertTrue(b.isClosed)
    }

    func testExplodeOneLevel() {
        let three = [line((0, 0), (10, 0)), line((10, 0), (10, 10))]
        let four = [line((50, 50), (60, 50)), line((60, 50), (60, 60))]
        let made = PathOps.makePath(three + four)
        let group = DesignObject(shape: .group(made))
        let level1 = PathOps.explode(group)
        XCTAssertEqual(level1.count, 2)
        let level2 = PathOps.explode(level1[0])
        XCTAssertEqual(level2.count, 2)
        if case .line(let a, let b) = level2[1].shape {
            XCTAssertEqual(a, TSDPoint(x: 10, y: 0)); XCTAssertEqual(b, TSDPoint(x: 10, y: 10))
        } else { XCTFail("segment should read back as a line") }
        let rect = DesignObject(shape: .rect(TSDRect(minX: 0, minY: 0, maxX: 10, maxY: 5)))
        XCTAssertEqual(PathOps.explode(rect).count, 4)
    }

    func testReversedCurveKeepsShape() {
        let c = PathOps.Chain(start: TSDPoint(x: 0, y: 0), segments: [.curve(TSDPoint(x: 1, y: 2), TSDPoint(x: 3, y: 2), TSDPoint(x: 4, y: 0))])
        let r = c.reversed()
        XCTAssertEqual(r.start, TSDPoint(x: 4, y: 0))
        XCTAssertEqual(r.segments, [.curve(TSDPoint(x: 3, y: 2), TSDPoint(x: 1, y: 2), TSDPoint(x: 0, y: 0))])
    }
}
