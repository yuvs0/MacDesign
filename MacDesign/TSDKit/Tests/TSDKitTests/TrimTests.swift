import XCTest
@testable import TSDKit

final class TrimTests: XCTestCase {
    private func obj(_ s: Shape) -> DesignObject { DesignObject(style: Style(strokeColor: .black), shape: s) }

    func testSegmentIntersection() {
        let hit = Trim.intersect(TSDPoint(x: 0, y: 0), TSDPoint(x: 10, y: 10), TSDPoint(x: 0, y: 10), TSDPoint(x: 10, y: 0))
        XCTAssertEqual(hit?.t ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(hit?.u ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(Trim.intersect(TSDPoint(x: 0, y: 0), TSDPoint(x: 10, y: 0), TSDPoint(x: 0, y: 1), TSDPoint(x: 10, y: 1)))
    }

    func testLineCrossedTwiceLeavesTwoLines() {
        let line = obj(.line(TSDPoint(x: 0, y: 0), TSDPoint(x: 100, y: 0)))
        let cutters = [obj(.line(TSDPoint(x: 30, y: -10), TSDPoint(x: 30, y: 10))), obj(.line(TSDPoint(x: 70, y: -10), TSDPoint(x: 70, y: 10)))]
        let result = Trim.deleteBetweenIntersections(of: line, at: TSDPoint(x: 50, y: 0.1), others: cutters)
        XCTAssertEqual(result?.count, 2)
        guard case .line(let a, let b)? = result?.first, case .line(let c, let d)? = result?.last else { return XCTFail("expected lines") }
        XCTAssertEqual(a.x, 0, accuracy: 1e-9); XCTAssertEqual(b.x, 30, accuracy: 1e-9)
        XCTAssertEqual(c.x, 70, accuracy: 1e-9); XCTAssertEqual(d.x, 100, accuracy: 1e-9)
    }

    func testLineCrossedOnceTrimsToEnd() {
        let line = obj(.line(TSDPoint(x: 0, y: 0), TSDPoint(x: 100, y: 0)))
        let cutter = obj(.line(TSDPoint(x: 30, y: -10), TSDPoint(x: 30, y: 10)))
        let result = Trim.deleteBetweenIntersections(of: line, at: TSDPoint(x: 80, y: 0), others: [cutter])
        XCTAssertEqual(result?.count, 1)
        guard case .line(let a, let b)? = result?.first else { return XCTFail("expected a line") }
        XCTAssertEqual(a.x, 0, accuracy: 1e-9); XCTAssertEqual(b.x, 30, accuracy: 1e-9)
    }

    func testUncrossedLineIsDeleted() {
        let line = obj(.line(TSDPoint(x: 0, y: 0), TSDPoint(x: 100, y: 0)))
        XCTAssertEqual(Trim.deleteBetweenIntersections(of: line, at: TSDPoint(x: 50, y: 0), others: [])?.count, 0)
    }

    func testCircleCrossedByLineLeavesArc() {
        let circle = obj(.circle(center: .zero, radius: 10))
        let cutter = obj(.line(TSDPoint(x: -20, y: 0), TSDPoint(x: 20, y: 0)))
        // Click the top: the top half goes, the bottom half stays as an arc from 180° to 360°.
        let result = Trim.deleteBetweenIntersections(of: circle, at: TSDPoint(x: 0, y: 10), others: [cutter])
        XCTAssertEqual(result?.count, 1)
        guard case .arc(let c, let rx, _, let a0, let a1)? = result?.first else { return XCTFail("expected an arc") }
        XCTAssertEqual(c.x, 0, accuracy: 1e-9); XCTAssertEqual(rx, 10, accuracy: 1e-9)
        XCTAssertEqual(a0, 180, accuracy: 0.5); XCTAssertEqual(a1, 360, accuracy: 0.5)
    }

    func testRectangleSideRemoved() {
        let rect = obj(.rect(TSDRect(minX: 0, minY: 0, maxX: 100, maxY: 50)))
        let cutters = [obj(.line(TSDPoint(x: 30, y: 40), TSDPoint(x: 30, y: 60))), obj(.line(TSDPoint(x: 70, y: 40), TSDPoint(x: 70, y: 60)))]
        let result = Trim.deleteBetweenIntersections(of: rect, at: TSDPoint(x: 50, y: 50), others: cutters)
        XCTAssertEqual(result?.count, 1)
        guard case .path(let p)? = result?.first else { return XCTFail("expected a path") }
        XCTAssertFalse(p.isClosed)
        XCTAssertEqual(p.segments.first?.endPoint.x ?? -1, 70, accuracy: 1e-9)
        XCTAssertEqual(p.segments.last?.endPoint.x ?? -1, 30, accuracy: 1e-9)
    }

    func testIntersectionsNearPoint() {
        let a = obj(.line(TSDPoint(x: 0, y: 0), TSDPoint(x: 10, y: 10)))
        let b = obj(.line(TSDPoint(x: 0, y: 10), TSDPoint(x: 10, y: 0)))
        let hits = Trim.intersections(near: TSDPoint(x: 5.3, y: 4.8), tolerance: 1, objects: [a, b])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.x ?? -1, 5, accuracy: 1e-9)
    }

    func testGroupMemberTrimmedNotWholeGroup() {
        let a = obj(.line(TSDPoint(x: 0, y: 0), TSDPoint(x: 100, y: 0)))
        let b = obj(.line(TSDPoint(x: 0, y: 50), TSDPoint(x: 100, y: 50)))
        let group = obj(.group([a, b]))
        let cutters = [obj(.line(TSDPoint(x: 30, y: -10), TSDPoint(x: 30, y: 60))), obj(.line(TSDPoint(x: 70, y: -10), TSDPoint(x: 70, y: 60)))]
        let result = Trim.deleteBetweenIntersections(of: group, at: TSDPoint(x: 50, y: 0), others: cutters)
        XCTAssertEqual(result?.count, 1)
        guard case .group(let kids)? = result?.first else { return XCTFail("expected a group") }
        XCTAssertEqual(kids.count, 3)
    }
}
