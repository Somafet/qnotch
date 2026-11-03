import XCTest
import AppKit
@testable import QNotchMac
@testable import QNotchMacCore

final class NotchShapeTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 200)

    private func stroked(_ path: CGPath) -> CGPath {
        path.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    }

    /// The border runs up each side, around the shoulder flare and out to the top edge.
    func testIntegratedOutlineFollowsShoulderToTopEdge() {
        let flare = DisplayLayout.flare
        let edge = NotchShape.outline(rect, integrated: true, top: 0, bottom: 24)
        let ink = stroked(edge)
        XCTAssertEqual(edge.boundingBoxOfPath.maxY, rect.maxY, accuracy: 0.001, "outline reaches the top edge")
        XCTAssertEqual(edge.boundingBoxOfPath.minX, rect.minX + 0.5, accuracy: 0.001, "outline reaches the flare's outer tip")
        XCTAssertEqual(edge.boundingBoxOfPath.maxX, rect.maxX - 0.5, accuracy: 0.001)
        // The flare arc's midpoint (quadratic Bézier at t = 0.5, 4.5 in from the tip) carries ink; so does the side below it.
        for (x, side) in [(rect.minX + 0.5, CGFloat(1)), (rect.maxX - 0.5, CGFloat(-1))] {
            XCTAssertTrue(ink.contains(CGPoint(x: x + side * 4.5, y: rect.maxY - 1.5)), "ink on the arc")
            XCTAssertTrue(ink.contains(CGPoint(x: x + side * flare, y: rect.maxY - flare - 10)), "ink on the side")
            XCTAssertTrue(ink.contains(CGPoint(x: x + side * 0.1, y: rect.maxY - 0.1)) || ink.contains(CGPoint(x: x + side * 0.6, y: rect.maxY - 0.1)),
                          "ink at the arc's start on the top edge")
        }
        // The stroke stays inside the filled silhouette (no stray ink beyond the shape).
        let fill = NotchShape.path(rect, integrated: true, top: 0, bottom: 24)
        let ring = stroked(fill)
        XCTAssertTrue(ring.boundingBoxOfPath.contains(ink.boundingBoxOfPath.insetBy(dx: 0.5, dy: 0.5)))
    }

    /// One continuous subpath: no gap between the arc and the side.
    func testIntegratedOutlineIsOneSubpath() {
        var moves = 0
        NotchShape.outline(rect, integrated: true, top: 0, bottom: 24).applyWithBlock { element in
            if element.pointee.type == .moveToPoint { moves += 1 }
        }
        XCTAssertEqual(moves, 1)
    }

    /// The floating pill keeps its four rounded corners and does not reach past its rectangle.
    func testFloatingOutlineStaysInsideRect() {
        let edge = NotchShape.outline(rect, integrated: false, top: 16, bottom: 24)
        XCTAssertTrue(rect.insetBy(dx: 0.5, dy: 0.5).contains(edge.boundingBoxOfPath.insetBy(dx: 0.001, dy: 0.001)))
    }
}
