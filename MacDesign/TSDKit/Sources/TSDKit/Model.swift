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

/// Line pattern stored in an object's line block (see docs/FORMAT.md).
public enum LineType: Int, Codable, Sendable, CaseIterable {
    case none = 0
    case solid = 1
    /// 2D Design's broken patterns, repeating every `Style.dashScale` mm (1 by default).
    case dotted = 2
    case dashed = 3
    case longDash = 4

    public var name: String {
        switch self {
        case .none: return "None"
        case .solid: return "Solid"
        case .dotted: return "Dotted"
        case .dashed: return "Dashed"
        case .longDash: return "Long dash"
        }
    }
}

/// Hatch fill: parallel lines clipped to the shape.
public struct Hatch: Equatable, Hashable, Codable, Sendable {
    public var color: RGB
    /// Line width in mm; 0 is a hairline.
    public var lineWidth: Double
    /// Degrees anticlockwise from +x.
    public var angle: Double
    /// Distance between lines in mm.
    public var spacing: Double
    /// Second set of lines at right angles.
    public var isCrossed: Bool

    public init(color: RGB = .black, lineWidth: Double = 0, angle: Double = 45, spacing: Double = 4, isCrossed: Bool = false) {
        self.color = color
        self.lineWidth = lineWidth
        self.angle = angle
        self.spacing = spacing
        self.isCrossed = isCrossed
    }
}

public struct GradientStop: Equatable, Hashable, Codable, Sendable {
    public var color: RGB
    /// 0...1 along the gradient.
    public var position: Double

    public init(color: RGB, position: Double) {
        self.color = color
        self.position = position
    }
}

/// Linear gradient across the shape's bounds.
public struct Gradient: Equatable, Hashable, Codable, Sendable {
    public var stops: [GradientStop]
    /// Direction in degrees anticlockwise from +x; 0 runs left to right.
    public var angle: Double

    public init(stops: [GradientStop], angle: Double = 0) {
        self.stops = stops
        self.angle = angle
    }

    /// Start and end in the unit square of the shape's bounds (y up).
    public var start: TSDPoint {
        let r = angle * .pi / 180
        return TSDPoint(x: 0.5 - 0.5 * cos(r), y: 0.5 - 0.5 * sin(r))
    }

    public var end: TSDPoint {
        let r = angle * .pi / 180
        return TSDPoint(x: 0.5 + 0.5 * cos(r), y: 0.5 + 0.5 * sin(r))
    }
}

/// Texture (kind 4: an image from the file's texture table) or pattern (kind 5: a small
/// drawing), repeated in tiles of `tileSize` mm from the shape's top-left corner.
public struct FillPattern: Equatable, Hashable, Codable, Sendable {
    public static let texture = 4
    public static let drawing = 5

    public var kind: Int
    public var background: RGB?
    public var tile: [DesignObject]
    public var tileSize: TSDSize

    public init(kind: Int, background: RGB? = nil, tile: [DesignObject] = [], tileSize: TSDSize = TSDSize(width: 20, height: 20)) {
        self.kind = kind
        self.background = background
        self.tile = tile
        self.tileSize = tileSize
    }
}

public enum Fill: Equatable, Hashable, Codable, Sendable {
    case none
    case solid(RGB)
    case hatch(Hatch)
    case gradient(Gradient)
    case pattern(FillPattern)

    public var name: String {
        switch self {
        case .none: return "None"
        case .solid: return "Solid"
        case .hatch: return "Hatch"
        case .gradient: return "Gradient"
        case .pattern(let p): return p.kind == FillPattern.texture ? "Texture" : "Pattern"
        }
    }

    /// Hatch, gradient or pattern: fills MacDesign shows and keeps but can't create.
    public var isPreservedKind: Bool {
        switch self {
        case .none, .solid: return false
        case .hatch, .gradient, .pattern: return true
        }
    }

    /// A single colour that stands in for this fill in swatches and simple exports.
    public var representativeColor: RGB? {
        switch self {
        case .none: return nil
        case .solid(let c): return c
        case .hatch(let h): return h.color
        case .gradient(let g): return g.stops.first?.color
        case .pattern(let p): return p.background ?? RGB(r: 200, g: 200, b: 200)
        }
    }
}

/// Line and fill, as stored in every record's line block and fill block.
public struct Style: Equatable, Hashable, Codable, Sendable {
    /// nil is the default colour (black).
    public var strokeColor: RGB?
    /// Line width in mm. 0 is 2D Design's default hairline.
    public var strokeWidth: Double
    public var lineType: LineType
    /// Scale of the dash pattern for broken lines (1 in every sample).
    public var dashScale: Double
    public var fill: Fill

    public init(strokeColor: RGB? = nil, fillColor: RGB? = nil, strokeWidth: Double = 0.25,
                lineType: LineType = .solid, fill: Fill? = nil) {
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.lineType = lineType
        self.dashScale = 1
        self.fill = fill ?? fillColor.map { .solid($0) } ?? .none
    }

    /// Solid fill colour. Setting it replaces any other kind of fill.
    public var fillColor: RGB? {
        get { if case .solid(let c) = fill { return c } else { return nil } }
        set { fill = newValue.map { .solid($0) } ?? .none }
    }

    public var isFilled: Bool { fill != .none }
    public var isStroked: Bool { lineType != .none }

    public var effectiveStroke: RGB { strokeColor ?? .black }

    /// Width a hairline (stored width 0) is drawn at, in mm.
    public static let hairline = 0.18

    public var effectiveStrokeWidth: Double { strokeWidth > 0 ? strokeWidth : Style.hairline }
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
    /// Text height in mm: the height of capital letters, as 2D Design measures it.
    public var fontSize: Double
    public var isBold: Bool
    public var isItalic: Bool
    /// Raw Windows LOGFONT (92 bytes) and the 90-byte tail that follows it, kept so an
    /// unedited text round-trips exactly. nil for text created here.
    public var rawLogFont: Data?
    public var rawFontTail: Data?
    /// Line and fill blocks of the font and glyph sub-records as read.
    public var rawFontStyle: Data?
    public var rawGlyphStyle: Data?
    /// The three bytes between the text's second point and its font record (zero, or
    /// 01 00 01 for the label of a dimension). Meaning unknown; preserved.
    public var rawFlags: Data?
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

    /// Approximate em size in mm as drawn. `fontSize` is 2D Design's text height, the
    /// height of capitals; Renderer uses the real font's cap height instead of 0.716 (Arial).
    public var renderedSize: Double { fontSize * scaleY / 0.716 }
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
    /// Record type as read (see Record.Kind). Arcs, Bézier curves, dimensions and arrows keep
    /// their type while unchanged; once edited they are saved as paths or groups.
    public var recordType: UInt16?
    /// Bytes that preceded this record in the file (an unexplained 04 00 seen before point records).
    public var prefixBytes: Data
    /// The 14 header bytes after the object number (6 zero, 8 FF in every file), and the two
    /// strings that follow (";" in every file).
    public var rawHeader: Data?
    public var rawNames: [String]?
    /// Line and fill blocks as read, and the style decoded from them, so an unchanged
    /// line or fill is written back exactly.
    public var rawStyle: Data?
    public var rawFill: Data?
    public var loadedStyle: Style?
    /// The record body as read, written back verbatim while shape, layer, number and style
    /// are unchanged.
    public var rawBody: RawBody?
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

    public var displayName: String {
        if let name { return name }
        switch recordType {
        case Record.Kind.dimension.rawValue?: return "Dimension"
        case Record.Kind.doubleLine.rawValue?: return "Double line"
        default: return shape.kindName
        }
    }
}

/// A record body kept verbatim, with what it was read alongside.
public struct RawBody: Equatable, Hashable, Codable, Sendable {
    public var data: Data
    public var shape: Shape
    public var layer: Int
    public var fileID: UInt16
    public var style: Style

    public func matches(_ o: DesignObject) -> Bool {
        o.shape == shape && o.layer == layer && o.fileID == fileID && o.style == style
    }
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
    /// JPEG images from the prefix's texture table, used by texture fills. Not saved
    /// separately (the prefix holds them).
    public var textures: [Data] = []
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
