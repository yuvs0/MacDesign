import Foundation

// All coordinates are millimetres on the sheet, origin bottom-left, y up.

public struct TSDPoint: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = TSDPoint(x: 0, y: 0)

    public func offset(dx: Double, dy: Double) -> TSDPoint { TSDPoint(x: x + dx, y: y + dy) }

    public func distance(to p: TSDPoint) -> Double {
        ((x - p.x) * (x - p.x) + (y - p.y) * (y - p.y)).squareRoot()
    }
}

public struct TSDSize: Equatable, Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct TSDRect: Equatable, Hashable, Codable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = min(minX, maxX)
        self.minY = min(minY, maxY)
        self.maxX = max(minX, maxX)
        self.maxY = max(minY, maxY)
    }

    public init(p1: TSDPoint, p2: TSDPoint) {
        self.init(minX: p1.x, minY: p1.y, maxX: p2.x, maxY: p2.y)
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: TSDPoint { TSDPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
    public var isEmpty: Bool { width <= 0 && height <= 0 }

    public func union(_ r: TSDRect) -> TSDRect {
        TSDRect(minX: min(minX, r.minX), minY: min(minY, r.minY), maxX: max(maxX, r.maxX), maxY: max(maxY, r.maxY))
    }

    public func insetBy(_ d: Double) -> TSDRect {
        TSDRect(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d)
    }

    public func contains(_ p: TSDPoint) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    public func intersects(_ r: TSDRect) -> Bool {
        !(r.minX > maxX || r.maxX < minX || r.minY > maxY || r.maxY < minY)
    }

    public static func bounding(_ points: [TSDPoint]) -> TSDRect? {
        guard let f = points.first else { return nil }
        var r = TSDRect(minX: f.x, minY: f.y, maxX: f.x, maxY: f.y)
        for p in points.dropFirst() {
            r.minX = min(r.minX, p.x); r.maxX = max(r.maxX, p.x)
            r.minY = min(r.minY, p.y); r.maxY = max(r.maxY, p.y)
        }
        return r
    }
}

/// 8-bit RGB colour. 2D Design stores these as Windows COLORREF (0x00BBGGRR).
public struct RGB: Equatable, Hashable, Codable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(colorref: UInt32) {
        r = UInt8(colorref & 0xFF)
        g = UInt8((colorref >> 8) & 0xFF)
        b = UInt8((colorref >> 16) & 0xFF)
    }

    public var colorref: UInt32 { UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    public static let black = RGB(r: 0, g: 0, b: 0)
    public static let white = RGB(r: 255, g: 255, b: 255)
    public static let red = RGB(r: 255, g: 0, b: 0)
    public static let blue = RGB(r: 0, g: 0, b: 255)
    public static let green = RGB(r: 0, g: 128, b: 0)
}

/// Stroke and fill. 2D Design only stores the pen colour in a known place; the fill
/// fields are written into spare bytes of the same block (see docs/FORMAT.md) and
/// are experimental.
public struct Style: Equatable, Hashable, Codable, Sendable {
    /// nil means the object has no explicit pen record in the file (drawn black).
    public var strokeColor: RGB?
    public var fillColor: RGB?
    /// Display and export only; 2D Design maps colours to pens rather than storing widths.
    public var strokeWidth: Double

    public init(strokeColor: RGB? = nil, fillColor: RGB? = nil, strokeWidth: Double = 0.25) {
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.strokeWidth = strokeWidth
    }

    public var effectiveStroke: RGB { strokeColor ?? .black }
}

public enum PathSegment: Equatable, Hashable, Codable, Sendable {
    case move(TSDPoint)
    case line(TSDPoint)
    /// Cubic Bézier: control 1, control 2, end point.
    case curve(TSDPoint, TSDPoint, TSDPoint)

    public var endPoint: TSDPoint {
        switch self {
        case .move(let p), .line(let p): return p
        case .curve(_, _, let e): return e
        }
    }
}

public struct PathData: Equatable, Hashable, Codable, Sendable {
    public var segments: [PathSegment]
    public var isClosed: Bool

    public init(segments: [PathSegment], isClosed: Bool) {
        self.segments = segments
        self.isClosed = isClosed
    }

    /// Every point the path touches, control points included.
    public var allPoints: [TSDPoint] {
        segments.flatMap { seg -> [TSDPoint] in
            switch seg {
            case .move(let p), .line(let p): return [p]
            case .curve(let c1, let c2, let e): return [c1, c2, e]
            }
        }
    }
}

public struct TextData: Equatable, Hashable, Codable, Sendable {
    public var string: String
    /// Baseline origin of the first character.
    public var origin: TSDPoint
    public var scaleX: Double
    public var scaleY: Double
    /// Second point stored with the text. Meaning not confirmed; preserved on round trip.
    public var anchor: TSDPoint
    public var fontFace: String
    /// Nominal size in mm (the value 2D Design keeps at the end of the font record).
    public var fontSize: Double
    public var isBold: Bool
    public var isItalic: Bool
    /// Raw Windows LOGFONT (92 bytes) and the 90-byte tail that follows it, kept so an
    /// unedited text round-trips exactly. nil for text created here.
    public var rawLogFont: Data?
    public var rawFontTail: Data?
    /// Pen blocks of the font and glyph sub-records as read (17 bytes or empty).
    public var rawFontStyle: Data?
    public var rawGlyphStyle: Data?
    /// Pen position of each non-space character as stored in the file. nil until read, or
    /// after an edit that changes the characters; the writer then measures the font itself.
    public var rawGlyphPositions: [TSDPoint]?

    public init(string: String, origin: TSDPoint, fontFace: String = "Arial", fontSize: Double = 5,
                scaleX: Double = 1, scaleY: Double = 1, anchor: TSDPoint = .zero,
                isBold: Bool = false, isItalic: Bool = false,
                rawLogFont: Data? = nil, rawFontTail: Data? = nil) {
        self.string = string
        self.origin = origin
        self.fontFace = fontFace
        self.fontSize = fontSize
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.anchor = anchor
        self.isBold = isBold
        self.isItalic = isItalic
        self.rawLogFont = rawLogFont
        self.rawFontTail = rawFontTail
    }

    /// Em size in mm as drawn.
    public var renderedSize: Double { fontSize * scaleY }
}

public indirect enum Shape: Equatable, Hashable, Codable, Sendable {
    case path(PathData)
    case line(TSDPoint, TSDPoint)
    /// Native 2D Design circle: centre and radius.
    case circle(center: TSDPoint, radius: Double)
    /// Stored as a Bézier path in the file.
    case ellipse(center: TSDPoint, rx: Double, ry: Double)
    /// Axis-aligned rectangle; stored as a polyline in the file.
    case rect(TSDRect)
    /// Elliptical arc, angles in degrees anticlockwise from +x; stored as a Bézier path.
    case arc(center: TSDPoint, rx: Double, ry: Double, startAngle: Double, endAngle: Double)
    case point(TSDPoint)
    case text(TextData)
    case group([DesignObject])

    public var kindName: String {
        switch self {
        case .path: return "Path"
        case .line: return "Line"
        case .circle: return "Circle"
        case .ellipse: return "Ellipse"
        case .rect: return "Rectangle"
        case .arc: return "Arc"
        case .point: return "Point"
        case .text(let t): return "Text “\(t.string)”"
        case .group(let items): return "Group (\(items.count))"
        }
    }

    public var systemImage: String {
        switch self {
        case .path: return "scribble"
        case .line: return "line.diagonal"
        case .circle, .ellipse: return "circle"
        case .rect: return "rectangle"
        case .arc: return "arrow.counterclockwise"
        case .point: return "smallcircle.filled.circle"
        case .text: return "textformat"
        case .group: return "square.on.square"
        }
    }
}

public struct DesignObject: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: UUID
    /// Object number inside the 2D Design file. Members of a group share their group's number.
    public var fileID: UInt16
    public var name: String?
    /// 1-based index into TSDDocument.layers (matches Layer.index).
    public var layer: Int
    public var isVisible: Bool
    public var isLocked: Bool
    public var style: Style
    public var shape: Shape
    /// Original record type for lines (0x05) and circles (0x06); preserved on round trip.
    public var recordType: UInt16?
    /// Bytes that preceded this record in the file (an unexplained 04 00 seen before point records).
    public var prefixBytes: Data
    /// The 12 header bytes after the pen block, kept verbatim apart from the layer field.
    public var rawHeader: Data?
    /// The 17-byte pen block as read, and the style decoded from it, so an unchanged
    /// style is written back exactly.
    public var rawStyle: Data?
    public var loadedStyle: Style?
    /// For circles: the point on the circumference the file stored (2D Design keeps the
    /// point the user clicked). Kept so unchanged circles round-trip exactly.
    public var rawCirclePoint: TSDPoint?

    public init(id: UUID = UUID(), fileID: UInt16 = 0, name: String? = nil, layer: Int = 1,
                isVisible: Bool = true, isLocked: Bool = false,
                style: Style = Style(), shape: Shape,
                recordType: UInt16? = nil, prefixBytes: Data = Data(), rawHeader: Data? = nil) {
        self.id = id
        self.fileID = fileID
        self.name = name
        self.layer = layer
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.style = style
        self.shape = shape
        self.recordType = recordType
        self.prefixBytes = prefixBytes
        self.rawHeader = rawHeader
    }

    public var displayName: String { name ?? shape.kindName }
}

public struct Layer: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// 1-based index stored in the file.
    public var index: Int
    public var isVisible: Bool
    public var isLocked: Bool
    /// The two flag bytes after the index (01 01 in every sample). Preserved.
    public var rawFlags: Data

    public init(id: UUID = UUID(), name: String, index: Int, isVisible: Bool = true, isLocked: Bool = false,
                rawFlags: Data = Data([1, 1])) {
        self.id = id
        self.name = name
        self.index = index
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.rawFlags = rawFlags
    }
}

public struct TSDDocument: Equatable, Codable, Sendable {
    public var signature: String
    public var version: String
    public var pageName: String?
    public var pageSize: TSDSize
    /// Bottom of the stack first.
    public var layers: [Layer]
    /// Z-order, bottom first.
    public var objects: [DesignObject]
    /// Everything before the layer table: header, textures, hidden template graphic, page setup.
    public var prefix: Data
    /// Hatch, pen and settings tables between the layers and the objects.
    public var middle: Data
    public var trailer: Data
    /// True when the file was read with the fallback scanner and cannot be saved back as .3vs.
    public var isReadOnly: Bool
    /// Why the structured reader gave up, when isReadOnly is set.
    public var fallbackReason: String?

    public init(signature: String = "tsdtdv3", version: String = "V3.28", pageName: String? = "ISO A3 (420mm x 297mm)",
                pageSize: TSDSize = TSDSize(width: 420, height: 297),
                layers: [Layer] = [], objects: [DesignObject] = [],
                prefix: Data = Data(), middle: Data = Data(), trailer: Data = TSDDocument.standardTrailer,
                isReadOnly: Bool = false) {
        self.signature = signature
        self.version = version
        self.pageName = pageName
        self.pageSize = pageSize
        self.layers = layers
        self.objects = objects
        self.prefix = prefix
        self.middle = middle
        self.trailer = trailer
        self.isReadOnly = isReadOnly
    }

    public static let standardTrailer = Data([
        0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ])

    /// A blank A3 document built from the bundled template.
    public static func blank() -> TSDDocument {
        var doc = TSDDocument()
        doc.layers = [Layer(name: "Layer 1", index: 1), Layer(name: "Layer 2", index: 2), Layer(name: "Layer 3", index: 3)]
        doc.prefix = Template.prefix
        doc.middle = Template.middle
        return doc
    }

    public func layer(withIndex index: Int) -> Layer? {
        layers.first { $0.index == index }
    }

    public var nextFileID: UInt16 {
        var maxID: UInt16 = 0
        func walk(_ objs: [DesignObject]) {
            for o in objs {
                maxID = max(maxID, o.fileID)
                if case .group(let kids) = o.shape { walk(kids) }
            }
        }
        walk(objects)
        return maxID &+ 1
    }

    /// Bounding box of all geometry, or nil if empty.
    public var bounds: TSDRect? {
        var result: TSDRect?
        for o in objects {
            guard let b = Geometry.bounds(of: o) else { continue }
            result = result.map { $0.union(b) } ?? b
        }
        return result
    }

    // MARK: Object lookup and editing helpers

    public func object(with id: UUID) -> DesignObject? {
        func find(_ objs: [DesignObject]) -> DesignObject? {
            for o in objs {
                if o.id == id { return o }
                if case .group(let kids) = o.shape, let f = find(kids) { return f }
            }
            return nil
        }
        return find(objects)
    }

    /// Applies `body` to the top-level object with this id. Returns false if not found.
    @discardableResult
    public mutating func update(_ id: UUID, _ body: (inout DesignObject) -> Void) -> Bool {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return false }
        body(&objects[i])
        return true
    }

    public mutating func remove(ids: Set<UUID>) {
        objects.removeAll { ids.contains($0.id) }
    }
}

enum Template {
    static let prefix: Data = load("template-prefix")
    static let middle: Data = load("template-middle")

    private static func load(_ name: String) -> Data {
        if let url = Bundle.module.url(forResource: name, withExtension: "bin"),
           let d = try? Data(contentsOf: url) {
            return d
        }
        return Data()
    }
}
