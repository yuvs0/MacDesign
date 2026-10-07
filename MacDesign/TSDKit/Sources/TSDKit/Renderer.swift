#if canImport(CoreGraphics) && canImport(CoreText)
import Foundation
import CoreGraphics
import CoreText

/// Draws documents into a CGContext whose units are millimetres with y pointing up
/// (the file's own coordinate system). The app canvas, PDF and PNG export all use this.
public enum Renderer {

    public struct Options {
        public var respectVisibility = true
        /// Objects drawn with this stroke colour override (for printing all-black, say).
        public var strokeOverride: RGB?
        /// Minimum stroke width in mm, so hairlines stay visible at small zoom.
        public var minimumStrokeWidth: Double = 0
        public var hiddenLayers: Set<Int> = []
        public init() {}
    }

    public static func draw(_ doc: TSDDocument, in ctx: CGContext, options: Options = Options()) {
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for o in doc.objects {
            draw(o, in: ctx, doc: doc, options: options)
        }
    }

    public static func draw(_ o: DesignObject, in ctx: CGContext, doc: TSDDocument, options: Options) {
        if options.respectVisibility {
            if !o.isVisible { return }
            if options.hiddenLayers.contains(o.layer) { return }
            if let layer = doc.layer(withIndex: o.layer), !layer.isVisible { return }
        }
        switch o.shape {
        case .group(let kids):
            for k in kids { draw(k, in: ctx, doc: doc, options: options) }
        case .text(let t):
            drawText(t, style: o.style, in: ctx, options: options)
        case .point(let p):
            let r = 0.6
            ctx.setFillColor(cgColor(options.strokeOverride ?? o.style.effectiveStroke))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        default:
            guard let path = cgPath(for: o.shape) else { return }
            if let fill = o.style.fillColor {
                ctx.setFillColor(cgColor(fill))
                ctx.addPath(path)
                ctx.fillPath(using: .evenOdd)
            }
            ctx.setStrokeColor(cgColor(options.strokeOverride ?? o.style.effectiveStroke))
            ctx.setLineWidth(max(o.style.strokeWidth, options.minimumStrokeWidth))
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    public static func cgColor(_ c: RGB) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    // MARK: Paths

    public static func cgPath(for shape: Shape) -> CGPath? {
        switch shape {
        case .circle(let c, let r):
            return CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
        case .ellipse(let c, let rx, let ry):
            return CGPath(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
        case .rect(let r):
            return CGPath(rect: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height), transform: nil)
        case .text(let t):
            return textPath(t)
        case .group(let kids):
            let p = CGMutablePath()
            for k in kids { if let kp = cgPath(for: k.shape) { p.addPath(kp) } }
            return p
        default:
            guard let data = Geometry.path(for: shape) else { return nil }
            return cgPath(for: data)
        }
    }

    public static func cgPath(for data: PathData) -> CGPath {
        let path = CGMutablePath()
        for seg in data.segments {
            switch seg {
            case .move(let p): path.move(to: CGPoint(x: p.x, y: p.y))
            case .line(let p): path.addLine(to: CGPoint(x: p.x, y: p.y))
            case .curve(let c1, let c2, let e):
                path.addCurve(to: CGPoint(x: e.x, y: e.y), control1: CGPoint(x: c1.x, y: c1.y), control2: CGPoint(x: c2.x, y: c2.y))
            }
        }
        if data.isClosed { path.closeSubpath() }
        return path
    }

    // MARK: Text

    /// Resolves the font named in the file, falling back to the system font (SF Pro) when it isn't installed.
    public static func font(for t: TextData) -> CTFont {
        let size = CGFloat(max(t.renderedSize, 0.1))
        var base: CTFont
        if fontFamilyIsInstalled(t.fontFace) {
            base = CTFontCreateWithName(t.fontFace as CFString, size, nil)
        } else {
            base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        var traits: CTFontSymbolicTraits = []
        if t.isBold { traits.insert(.boldTrait) }
        if t.isItalic { traits.insert(.italicTrait) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) {
            base = styled
        }
        return base
    }

    public static func fontFamilyIsInstalled(_ family: String) -> Bool {
        let attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: family]
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        let mandatory: Set<CFString> = [kCTFontFamilyNameAttribute]
        return CTFontDescriptorCreateMatchingFontDescriptor(desc, mandatory as CFSet) != nil
    }

    static func line(for t: TextData) -> CTLine {
        let font = font(for: t)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: t.string, attributes: attrs))
    }

    /// Text outline in document coordinates (used for hit testing and export).
    /// Glyphs use the pen positions stored in the file when they are present.
    public static func textPath(_ t: TextData) -> CGPath {
        let line = line(for: t)
        let result = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as NSArray
        let chars = Array(t.string.utf16)
        let stored = t.rawGlyphPositions ?? []
        let useStored = stored.count == chars.filter { $0 != 0x20 }.count && !stored.isEmpty
        var glyphIndex = 0
        for run in runs {
            let run = run as! CTRun
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            for i in 0..<count {
                let isSpace = indices[i] >= 0 && indices[i] < chars.count && chars[indices[i]] == 0x20
                var origin = CGPoint(x: t.origin.x + positions[i].x * t.scaleX / max(t.scaleY, 1e-9), y: t.origin.y + positions[i].y)
                if useStored, !isSpace, glyphIndex < stored.count {
                    origin = CGPoint(x: stored[glyphIndex].x, y: stored[glyphIndex].y)
                }
                if !isSpace { glyphIndex += 1 }
                var m = CGAffineTransform(translationX: origin.x, y: origin.y)
                m = m.scaledBy(x: t.scaleX / max(t.scaleY, 1e-9), y: 1)
                if let g = CTFontCreatePathForGlyph(runFont, glyphs[i], &m) {
                    result.addPath(g)
                }
            }
        }
        return result
    }

    /// Pen position of each non-space character, measured with the real font. nil if the
    /// string contains no glyphs.
    public static func glyphOrigins(for t: TextData) -> [TSDPoint]? {
        let line = line(for: t)
        let chars = Array(t.string.utf16)
        var result: [TSDPoint] = []
        let sx = t.scaleX / max(t.scaleY, 1e-9)
        for run in CTLineGetGlyphRuns(line) as NSArray {
            let run = run as! CTRun
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            for i in 0..<count {
                let idx = indices[i]
                if idx >= 0, idx < chars.count, chars[idx] == 0x20 { continue }
                result.append(TSDPoint(x: t.origin.x + positions[i].x * sx, y: t.origin.y + positions[i].y))
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Measured bounds of the text in mm.
    public static func textBounds(_ t: TextData) -> TSDRect {
        let line = line(for: t)
        let b = CTLineGetBoundsWithOptions(line, [])
        let sx = t.scaleX / max(t.scaleY, 1e-9)
        var r = TSDRect(minX: t.origin.x + b.minX * sx, minY: t.origin.y + b.minY,
                        maxX: t.origin.x + b.maxX * sx, maxY: t.origin.y + b.maxY)
        if r.width < 0.5 { r.maxX = r.minX + 0.5 }
        if r.height < 0.5 { r.maxY = r.minY + 0.5 }
        return r
    }

    static func drawText(_ t: TextData, style: Style, in ctx: CGContext, options: Options) {
        let path = textPath(t)
        ctx.setFillColor(cgColor(options.strokeOverride ?? style.fillColor ?? style.effectiveStroke))
        ctx.addPath(path)
        ctx.fillPath()
    }

    // MARK: Export

    public static func pdfData(for doc: TSDDocument, options: Options = Options()) -> Data {
        let mmToPt = 72.0 / 25.4
        var box = CGRect(x: 0, y: 0, width: doc.pageSize.width * mmToPt, height: doc.pageSize.height * mmToPt)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.scaleBy(x: mmToPt, y: mmToPt)
        var opts = options
        opts.minimumStrokeWidth = max(opts.minimumStrokeWidth, 0.1)
        draw(doc, in: ctx, options: opts)
        ctx.endPDFPage()
        ctx.closePDF()
        return output as Data
    }

    /// Renders the page to an RGBA bitmap at the given dots per millimetre.
    public static func image(for doc: TSDDocument, dotsPerMM: Double = 4, options: Options = Options()) -> CGImage? {
        let w = Int((doc.pageSize.width * dotsPerMM).rounded()), h = Int((doc.pageSize.height * dotsPerMM).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: dotsPerMM, y: dotsPerMM)
        var opts = options
        opts.minimumStrokeWidth = max(opts.minimumStrokeWidth, 1.5 / dotsPerMM)
        draw(doc, in: ctx, options: opts)
        return ctx.makeImage()
    }
}
#endif
