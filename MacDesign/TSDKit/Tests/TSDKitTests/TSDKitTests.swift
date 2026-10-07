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
        XCTAssertEqual(r.style.strokeColor, RGB(r: 0xC6, g: 0, b: 0))

        let circles = doc.objects.filter { if case .circle = $0.shape { return true } else { return false } }
        XCTAssertEqual(circles.count, 5)

        let texts = doc.objects.compactMap { o -> TextData? in if case .text(let t) = o.shape { return t } else { return nil } }
        XCTAssertEqual(texts.map { $0.string }, ["alex's clock", "fred is weird"])
        XCTAssertEqual(texts[0].fontFace, "Bauhaus 93")
        XCTAssertEqual(texts[0].fontSize, 5, accuracy: 1e-9)
    }

    func testRoundTripIsByteIdentical() throws {
        let url = try fixture("clock")
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
            XCTFail("Round trip differs: " + diffs.joined(separator: "\n"))
        }
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
