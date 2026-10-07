import Foundation

public enum ExportFormat: String, CaseIterable, Sendable {
    case svg, dxf, json

    public var fileExtension: String { rawValue }
}

public enum Exporter {
    public static func data(for doc: TSDDocument, format: ExportFormat) throws -> Data {
        switch format {
        case .svg: return Data(SVGExporter.string(for: doc).utf8)
        case .dxf: return Data(DXFExporter.string(for: doc).utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var copy = doc
            copy.prefix = Data(); copy.middle = Data(); copy.trailer = Data()
            return try encoder.encode(copy)
        }
    }
}

func fmt(_ v: Double) -> String {
    let rounded = (v * 1000).rounded() / 1000
    if rounded == rounded.rounded() { return String(Int(rounded)) }
    return String(rounded)
}

/// Visible objects grouped by layer, bottom layer first.
func visibleObjectsByLayer(_ doc: TSDDocument) -> [(Layer, [DesignObject])] {
    doc.layers.compactMap { layer in
        guard layer.isVisible else { return nil }
        let objs = doc.objects.filter { $0.layer == layer.index && $0.isVisible }
        return (layer, objs)
    }
}

// MARK: - SVG

/// SVG in millimetres. SVG's y axis points down, so y is flipped against the page height.
public enum SVGExporter {
    public static func string(for doc: TSDDocument) -> String {
        let w = doc.pageSize.width, h = doc.pageSize.height
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="\(fmt(w))mm" height="\(fmt(h))mm" viewBox="0 0 \(fmt(w)) \(fmt(h))">
        <!-- Exported from 2D Design \(doc.version) by MacDesign. Units are mm. -->

        """
        for (layer, objects) in visibleObjectsByLayer(doc) where !objects.isEmpty {
            out += "<g inkscape:groupmode=\"layer\" inkscape:label=\"\(escape(layer.name))\" id=\"\(escape(layer.name.replacingOccurrences(of: " ", with: "_")))\">\n"
            for o in objects { out += element(for: o, pageHeight: h, indent: "  ") }
            out += "</g>\n"
        }
        out += "</svg>\n"
        return out
    }

    static func element(for o: DesignObject, pageHeight h: Double, indent: String) -> String {
        func P(_ p: TSDPoint) -> String { "\(fmt(p.x)),\(fmt(h - p.y))" }
        let stroke = o.style.effectiveStroke.hex
        let fill = o.style.fillColor?.hex ?? "none"
        let common = "fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"\(fmt(o.style.strokeWidth))\""
        let name = o.name.map { " inkscape:label=\"\(escape($0))\"" } ?? ""

        switch o.shape {
        case .group(let kids):
            var s = "\(indent)<g\(name)>\n"
            for k in kids { s += element(for: k, pageHeight: h, indent: indent + "  ") }
            return s + "\(indent)</g>\n"
        case .text(let t):
            let family = "\(escape(t.fontFace)), sans-serif"
            let weight = t.isBold ? " font-weight=\"bold\"" : ""
            let style = t.isItalic ? " font-style=\"italic\"" : ""
            let color = (o.style.fillColor ?? o.style.effectiveStroke).hex
            let sx = t.scaleX / max(t.scaleY, 1e-9)
            let transform = abs(sx - 1) > 1e-6 ? " transform=\"translate(\(fmt(t.origin.x)) 0) scale(\(fmt(sx)) 1) translate(\(fmt(-t.origin.x)) 0)\"" : ""
            return "\(indent)<text x=\"\(fmt(t.origin.x))\" y=\"\(fmt(h - t.origin.y))\" font-family=\"\(family)\" font-size=\"\(fmt(t.renderedSize))\"\(weight)\(style) fill=\"\(color)\"\(transform)\(name)>\(escape(t.string))</text>\n"
        case .point(let p):
            return "\(indent)<circle cx=\"\(fmt(p.x))\" cy=\"\(fmt(h - p.y))\" r=\"0.5\" fill=\"\(stroke)\"\(name)/>\n"
        case .circle(let c, let r):
            return "\(indent)<circle cx=\"\(fmt(c.x))\" cy=\"\(fmt(h - c.y))\" r=\"\(fmt(r))\" \(common)\(name)/>\n"
        case .ellipse(let c, let rx, let ry):
            return "\(indent)<ellipse cx=\"\(fmt(c.x))\" cy=\"\(fmt(h - c.y))\" rx=\"\(fmt(rx))\" ry=\"\(fmt(ry))\" \(common)\(name)/>\n"
        case .rect(let r):
            return "\(indent)<rect x=\"\(fmt(r.minX))\" y=\"\(fmt(h - r.maxY))\" width=\"\(fmt(r.width))\" height=\"\(fmt(r.height))\" \(common)\(name)/>\n"
        case .line(let a, let b):
            return "\(indent)<line x1=\"\(fmt(a.x))\" y1=\"\(fmt(h - a.y))\" x2=\"\(fmt(b.x))\" y2=\"\(fmt(h - b.y))\" \(common)\(name)/>\n"
        default:
            guard let path = Geometry.path(for: o.shape) else { return "" }
            var d = ""
            for seg in path.segments {
                switch seg {
                case .move(let p): d += "M\(P(p)) "
                case .line(let p): d += "L\(P(p)) "
                case .curve(let c1, let c2, let e): d += "C\(P(c1)) \(P(c2)) \(P(e)) "
                }
            }
            if path.isClosed { d += "Z" }
            return "\(indent)<path d=\"\(d.trimmingCharacters(in: .whitespaces))\" \(common)\(name)/>\n"
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - DXF

/// ASCII DXF (R12 entities, with a LAYER table), units mm, y up like the source file.
/// Curves are flattened into short straight segments so any laser software can read them.
public enum DXFExporter {
    public static func string(for doc: TSDDocument, curveSteps: Int = 16) -> String {
        var lines: [String] = []
        func add(_ code: Int, _ value: String) {
            lines.append(String(code))
            lines.append(value)
        }

        add(0, "SECTION"); add(2, "HEADER")
        add(9, "$ACADVER"); add(1, "AC1009")
        add(9, "$INSUNITS"); add(70, "4")
        add(0, "ENDSEC")

        add(0, "SECTION"); add(2, "TABLES")
        add(0, "TABLE"); add(2, "LAYER"); add(70, String(doc.layers.count))
        for layer in doc.layers {
            add(0, "LAYER"); add(2, layerName(layer)); add(70, "0"); add(62, "7"); add(6, "CONTINUOUS")
        }
        add(0, "ENDTAB")
        add(0, "ENDSEC")

        add(0, "SECTION"); add(2, "ENTITIES")
        for (layer, objects) in visibleObjectsByLayer(doc) {
            for o in objects { entity(o, layer: layerName(layer), steps: curveSteps, add: add) }
        }
        add(0, "ENDSEC"); add(0, "EOF")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func layerName(_ layer: Layer) -> String {
        let cleaned = layer.name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        return cleaned.isEmpty ? "LAYER_\(layer.index)" : cleaned
    }

    static func entity(_ o: DesignObject, layer: String, steps: Int, add: (Int, String) -> Void) {
        let color = String(aci(o.style.effectiveStroke))
        func common(_ type: String) {
            add(0, type); add(8, layer); add(62, color)
        }
        switch o.shape {
        case .group(let kids):
            for k in kids { entity(k, layer: layer, steps: steps, add: add) }
        case .line(let a, let b):
            common("LINE")
            add(10, fmt(a.x)); add(20, fmt(a.y)); add(30, "0")
            add(11, fmt(b.x)); add(21, fmt(b.y)); add(31, "0")
        case .circle(let c, let r):
            common("CIRCLE")
            add(10, fmt(c.x)); add(20, fmt(c.y)); add(30, "0"); add(40, fmt(r))
        case .arc(let c, let rx, let ry, let a0, let a1) where abs(rx - ry) < 1e-9:
            common("ARC")
            add(10, fmt(c.x)); add(20, fmt(c.y)); add(30, "0"); add(40, fmt(rx))
            add(50, fmt(a0)); add(51, fmt(a1))
        case .point(let p):
            common("POINT")
            add(10, fmt(p.x)); add(20, fmt(p.y)); add(30, "0")
        case .text(let t):
            common("TEXT")
            add(10, fmt(t.origin.x)); add(20, fmt(t.origin.y)); add(30, "0")
            add(40, fmt(t.renderedSize * 0.72)); add(1, t.string)
        default:
            guard let path = Geometry.path(for: o.shape) else { return }
            for run in Geometry.polylines(path, steps: steps) where run.count >= 2 {
                var pts = run
                let closed = path.isClosed && pts.count > 2
                if closed, let f = pts.first, let l = pts.last, Geometry.near(f, l) { pts.removeLast() }
                common("POLYLINE"); add(66, "1"); add(70, closed ? "1" : "0")
                for p in pts {
                    add(0, "VERTEX"); add(8, layer)
                    add(10, fmt(p.x)); add(20, fmt(p.y)); add(30, "0")
                }
                add(0, "SEQEND"); add(8, layer)
            }
        }
    }

    /// Nearest AutoCAD colour index for the common laser colours.
    static func aci(_ c: RGB) -> Int {
        let palette: [(Int, RGB)] = [
            (1, .red), (2, RGB(r: 255, g: 255, b: 0)), (3, RGB(r: 0, g: 255, b: 0)), (4, RGB(r: 0, g: 255, b: 255)),
            (5, .blue), (6, RGB(r: 255, g: 0, b: 255)), (7, .black), (7, .white), (8, RGB(r: 128, g: 128, b: 128)),
        ]
        var best = 7, bestD = Int.max
        for (i, p) in palette {
            let d = abs(Int(p.r) - Int(c.r)) + abs(Int(p.g) - Int(c.g)) + abs(Int(p.b) - Int(c.b))
            if d < bestD { bestD = d; best = i }
        }
        return best
    }
}
