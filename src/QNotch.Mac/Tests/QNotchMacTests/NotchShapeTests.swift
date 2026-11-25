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

    private func elements(_ path: CGPath) -> [CGPathElementType] {
        var types: [CGPathElementType] = []
        path.applyWithBlock { types.append($0.pointee.type) }
        return types
    }

    /// Core Animation morphs pill to panel only between paths with the same elements.
    func testPillAndPanelPathsMorph() {
        let pill = CGRect(x: 150, y: 168, width: 100, height: 32)
        for integrated in [false, true] {
            XCTAssertEqual(elements(NotchShape.path(pill, integrated: integrated, top: 16, bottom: 16)),
                           elements(NotchShape.path(rect, integrated: integrated, top: 20, bottom: PanelMetrics.bottomRadius, circular: true)))
            XCTAssertEqual(elements(NotchShape.outline(pill, integrated: integrated, top: 16, bottom: 16)),
                           elements(NotchShape.outline(rect, integrated: integrated, top: 20, bottom: PanelMetrics.bottomRadius, circular: true)))
        }
    }

    /// Element `index`'s start point and points.
    private func element(_ index: Int, of path: CGPath) -> (start: CGPoint, points: [CGPoint]) {
        var all: [[CGPoint]] = []
        path.applyWithBlock { pointer in
            let count: Int
            switch pointer.pointee.type {
            case .addCurveToPoint: count = 3
            case .addQuadCurveToPoint: count = 2
            case .closeSubpath: count = 0
            default: count = 1
            }
            all.append((0..<count).map { pointer.pointee.points[$0] })
        }
        return (all[index - 1].last ?? .zero, all[index])
    }

    private func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        let x: CGFloat = a * p0.x + b * p1.x + c * p2.x + d * p3.x
        let y: CGFloat = a * p0.y + b * p1.y + c * p2.y + d * p3.y
        return CGPoint(x: x, y: y)
    }

    /// The open panel's bottom corners are circular, so a card inset by the gap with the smaller
    /// radius stays an even distance from the panel's edge all the way round (spec: Concentric corners).
    func testPanelBottomCornersAreConcentricWithInsetCards() {
        let radius = PanelMetrics.bottomRadius, gap = PanelMetrics.inset
        XCTAssertEqual(PanelMetrics.cardRadius, radius - gap)
        let center = CGPoint(x: rect.minX + radius, y: rect.minY + radius)
        // Element 3 of the floating path is the bottom-left corner.
        let corner = element(3, of: NotchShape.path(rect, integrated: false, top: 20, bottom: radius, circular: true))
        XCTAssertEqual(corner.points.count, 3)
        for step in 0...20 {
            let point = cubic(corner.start, corner.points[0], corner.points[1], corner.points[2], CGFloat(step) / 20)
            // The card's corner arc (radius - gap about the same center) is `gap` inside at every angle.
            XCTAssertEqual(hypot(point.x - center.x, point.y - center.y) - (radius - gap), gap, accuracy: 0.03)
        }
    }

    /// The collapsed pill keeps its quadratic-looking corner: a cubic with handles at two thirds.
    func testPillCornerMatchesQuadratic() {
        let corner = element(3, of: NotchShape.path(rect, integrated: false, top: 16, bottom: 16))
        XCTAssertEqual(corner.start, CGPoint(x: rect.minX, y: rect.minY + 16))
        XCTAssertEqual(corner.points[0].x, rect.minX, accuracy: 0.0001)
        XCTAssertEqual(corner.points[0].y, rect.minY + 16.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(corner.points[1].x, rect.minX + 16.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(corner.points[1].y, rect.minY, accuracy: 0.0001)
    }
}
