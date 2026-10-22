import CoreGraphics
import XCTest
import QNotchMacCore

final class StatusGutterTests: XCTestCase {
    private let layout = DisplayLayout(frame: CGRect(x: -100, y: 200, width: 1512, height: 982),
                                       visibleFrame: CGRect(x: -100, y: 200, width: 1512, height: 945),
                                       safeTop: 37, cameraGap: CGRect(x: 560, y: 1145, width: 192, height: 37))

    func testAsymmetricValuesKeepOuterAnchors() throws {
        for leftWidth in [CGFloat(40), 55, 68] {
            for rightWidth in [CGFloat(90), 146] {
                try XCTContext.runActivity(named: "left=\(leftWidth), right=\(rightWidth)") { _ in
                    try checkOuterAnchors(leftWidth: leftWidth, rightWidth: rightWidth)
                }
            }
        }
    }

    private func checkOuterAnchors(leftWidth: CGFloat, rightWidth: CGFloat) throws {
        let wings = try XCTUnwrap(layout.wings(expanded: false, wing: 170))
        let left = try XCTUnwrap(StatusGutters.frame(size: CGSize(width: leftWidth, height: 17), in: wings.left, side: .left))
        let right = try XCTUnwrap(StatusGutters.frame(size: CGSize(width: rightWidth, height: 17), in: wings.right, side: .right))
        XCTAssertTrue(left.minX == 402)
        XCTAssertTrue(right.maxX == 910)
        XCTAssertTrue(left.midY == 1163.5 && right.midY == left.midY)
        XCTAssertTrue(left.maxX <= 548 && right.minX >= 764)
        XCTAssertTrue(layout.surface(expanded: false, wing: 170).midX == 656)
        // Opening changes the body, not the status anchors: use the same collapsed clear band.
        XCTAssertTrue(layout.surface(expanded: true, wing: 170).contains(left))
        XCTAssertTrue(layout.surface(expanded: true, wing: 170).contains(right))
    }

    func testWholeClustersRespectCameraAndOuterClearance() throws {
        for width in [CGFloat(0), 40, 146, 147, 220] {
            try XCTContext.runActivity(named: "width=\(width)") { _ in
                try checkClusterClearance(width: width)
            }
        }
    }

    private func checkClusterClearance(width: CGFloat) throws {
        let wings = try XCTUnwrap(layout.wings(expanded: false, wing: 170))
        let left = StatusGutters.frame(size: CGSize(width: width, height: 17), in: wings.left, side: .left)
        let right = StatusGutters.frame(size: CGSize(width: width, height: 17), in: wings.right, side: .right)
        XCTAssertTrue((left != nil) == (width > 0 && width <= 146))
        XCTAssertTrue((right != nil) == (width > 0 && width <= 146))
        XCTAssertTrue(StatusGutters.frame(size: CGSize(width: 40, height: 38), in: wings.left, side: .left) == nil)
    }

    func testOverflowStillSpillsWholeSegmentsBeforePlacement() throws {
        let shown = WingFit.fit(leading: [("cpu", 40.0)], trailing: [("weather", 70.0), ("ram", 40), ("timer", 40), ("too-wide", 200)],
                                maxWidth: 146, spacing: 6)
        XCTAssertTrue(shown.leading == ["timer", "cpu"])
        XCTAssertTrue(shown.trailing == ["weather", "ram"])
        let wings = try XCTUnwrap(layout.wings(expanded: false, wing: 144))
        XCTAssertTrue(StatusGutters.frame(size: CGSize(width: 86, height: 17), in: wings.left, side: .left)?.minX == 428)
        XCTAssertTrue(StatusGutters.frame(size: CGSize(width: 116, height: 17), in: wings.right, side: .right)?.maxX == 884)
    }

    func testIdleAndExternalDisplaysKeepTheirOwnGeometry() {
        XCTAssertTrue(layout.surface(expanded: false).width == 204)
        let empty = layout.wings(expanded: false)!
        XCTAssertTrue(StatusGutters.frame(size: CGSize(width: 40, height: 17), in: empty.left, side: .left) == nil)
        let external = DisplayLayout(frame: CGRect(x: -1920, y: -100, width: 1920, height: 1080),
                                     visibleFrame: CGRect(x: -1920, y: -100, width: 1920, height: 1055), safeTop: 0, cameraGap: nil)
        XCTAssertTrue(external.wings(expanded: false, wing: 120) == nil)
        XCTAssertTrue(external.surface(expanded: false, wing: 120) == CGRect(x: -1034, y: 917, width: 148, height: 32))
    }

    func testClampedWingOmitsContentRatherThanEnteringCamera() throws {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let tiny = DisplayLayout(frame: frame, visibleFrame: frame, safeTop: 37,
                                 cameraGap: CGRect(x: 64, y: 203, width: 192, height: 37))
        let wings = try XCTUnwrap(tiny.wings(expanded: false, wing: 170))
        XCTAssertTrue(StatusGutters.frame(size: CGSize(width: 40, height: 17), in: wings.left, side: .left) == nil)
        XCTAssertTrue(StatusGutters.frame(size: CGSize(width: 40, height: 17), in: wings.right, side: .right) == nil)
    }
}
