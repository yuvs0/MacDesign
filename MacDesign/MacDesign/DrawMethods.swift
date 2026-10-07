import Foundation
import TSDKit

/// The alternative ways of drawing with one tool, shown by pressing and holding its palette
/// button, as in 2D Design's tool flyouts.
enum DrawMethod: String, CaseIterable, Identifiable {
    case rectCorners, rectBounding, rectTilted, rectSized
    case ellipseCorners, circleCentre, ovalCentre, circleDiameter, circleThreePoints, circleTangent
    case lineEnds, lineLength, lineAngle, lineTangent
    case polygon, star
    case deleteObject, deleteBetween

    var id: String { rawValue }

    var tool: Tool {
        switch self {
        case .rectCorners, .rectBounding, .rectTilted, .rectSized: return .rectangle
        case .ellipseCorners, .circleCentre, .ovalCentre, .circleDiameter, .circleThreePoints, .circleTangent: return .ellipse
        case .lineEnds, .lineLength, .lineAngle, .lineTangent: return .line
        case .polygon, .star: return .polygon
        case .deleteObject, .deleteBetween: return .eraser
        }
    }

    var title: String {
        switch self {
        case .rectCorners: return "Rectangle"
        case .rectBounding: return "Rectangle Around an Object"
        case .rectTilted: return "Tilted Rectangle"
        case .rectSized: return "Rectangle of a Set Size"
        case .ellipseCorners: return "Ellipse"
        case .circleCentre: return "Circle from the Centre"
        case .ovalCentre: return "Oval from the Centre"
        case .circleDiameter: return "Circle Through Two Points"
        case .circleThreePoints: return "Circle Through Three Points"
        case .circleTangent: return "Tangent Circle"
        case .lineEnds: return "Line"
        case .lineLength: return "Line of a Set Length"
        case .lineAngle: return "Line at a Set Angle"
        case .lineTangent: return "Tangent Line"
        case .polygon: return "Polygon"
        case .star: return "Star"
        case .deleteObject: return "Delete Object"
        case .deleteBetween: return "Delete Between Intersections"
        }
    }

    /// Shown when the method is chosen.
    var hint: String {
        switch self {
        case .rectCorners: return "Drag from one corner to the opposite one"
        case .rectBounding: return "Tap an object to draw the rectangle that bounds it"
        case .rectTilted: return "Tap both ends of one side, then drag out the width"
        case .rectSized: return "Tap to place a rectangle of the size set in the inspector"
        case .ellipseCorners: return "Drag from one corner of the ellipse's box to the other"
        case .circleCentre: return "Drag from the centre to the edge"
        case .ovalCentre: return "Drag from the centre to a corner of the oval's box"
        case .circleDiameter: return "Drag from one side of the circle to the other"
        case .circleThreePoints: return "Tap two points on the circle, then drag the third"
        case .circleTangent: return "Tap the object to touch, then drag the circle's centre"
        case .lineEnds: return "Drag from one end to the other"
        case .lineLength: return "Drag to set the direction; the length is set in the inspector"
        case .lineAngle: return "Drag to set the length; the angle is set in the inspector"
        case .lineTangent: return "Tap a circle or arc near the tangent, then drag the far end"
        case .polygon: return "Drag from the centre to a corner; sides are set in the inspector"
        case .star: return "Drag from the centre to a point; points are set in the inspector"
        case .deleteObject: return "Tap an object to remove it, or sweep across several"
        case .deleteBetween: return "Tap a line or curve to remove it between its nearest crossings"
        }
    }

    /// Shown after the object or points the method starts with have been given.
    var nextHint: String {
        switch self {
        case .rectTilted: return "Now drag out the width"
        case .circleThreePoints: return "Now drag the third point"
        case .circleTangent: return "Now drag the circle's centre"
        case .lineTangent: return "Now drag the line's far end"
        default: return hint
        }
    }

    var systemImage: String {
        switch self {
        case .rectCorners: return "rectangle"
        case .rectBounding: return "rectangle.dashed"
        case .rectTilted: return "rhombus"
        case .rectSized: return "ruler"
        case .ellipseCorners: return "circle"
        case .circleCentre: return "smallcircle.filled.circle"
        case .ovalCentre: return "oval"
        case .circleDiameter: return "circle.lefthalf.filled"
        case .circleThreePoints: return "circle.dotted"
        case .circleTangent: return "circle.dashed"
        case .lineEnds: return "line.diagonal"
        case .lineLength: return "ruler"
        case .lineAngle: return "angle"
        case .lineTangent: return "circle.and.line.horizontal"
        case .polygon: return "pentagon"
        case .star: return "star"
        case .deleteObject: return "eraser"
        case .deleteBetween: return "eraser.line.dashed"
        }
    }

    /// Points placed by tapping before the final press and drag.
    var pointsFirst: Int {
        switch self {
        case .rectTilted, .circleThreePoints: return 2
        default: return 0
        }
    }

    /// Starts by tapping an existing object.
    var picksObject: Bool {
        switch self {
        case .rectBounding, .circleTangent, .lineTangent: return true
        default: return false
        }
    }

    static func methods(for tool: Tool) -> [DrawMethod] { allCases.filter { $0.tool == tool } }
    static func defaultMethod(for tool: Tool) -> DrawMethod? { methods(for: tool).first }
}
