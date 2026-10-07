import Foundation

/// Pen positions for each non-space character of a text object, in mm.
/// Uses CoreText when available; otherwise a rough fixed advance.
public enum TextLayout {
    public static func glyphOrigins(for t: TextData) -> [TSDPoint] {
        #if canImport(CoreText)
        if let measured = Renderer.glyphOrigins(for: t) { return measured }
        #endif
        var result: [TSDPoint] = []
        var x = t.origin.x
        for ch in t.string {
            if ch != " " { result.append(TSDPoint(x: x, y: t.origin.y)) }
            x += t.renderedSize * 0.55 * t.scaleX
        }
        return result
    }
}
