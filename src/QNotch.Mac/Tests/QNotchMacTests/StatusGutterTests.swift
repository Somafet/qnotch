import CoreGraphics
import Testing
import QNotchMacCore

struct StatusGutterTests {
    private let layout = DisplayLayout(frame: CGRect(x: -100, y: 200, width: 1512, height: 982),
                                       visibleFrame: CGRect(x: -100, y: 200, width: 1512, height: 945),
                                       safeTop: 37, cameraGap: CGRect(x: 560, y: 1145, width: 192, height: 37))

    @Test(arguments: [CGFloat(40), 55, 68], [CGFloat(90), 146])
    func asymmetricValuesKeepOuterAnchors(leftWidth: CGFloat, rightWidth: CGFloat) throws {
        let wings = try #require(layout.wings(expanded: false, wing: 170))
        let left = try #require(StatusGutters.frame(size: CGSize(width: leftWidth, height: 17), in: wings.left, side: .left))
        let right = try #require(StatusGutters.frame(size: CGSize(width: rightWidth, height: 17), in: wings.right, side: .right))
        #expect(left.minX == 402)
        #expect(right.maxX == 910)
        #expect(left.midY == 1163.5 && right.midY == left.midY)
        #expect(left.maxX <= 548 && right.minX >= 764)
        #expect(layout.surface(expanded: false, wing: 170).midX == 656)
        // Opening changes the body, not the status anchors: use the same collapsed clear band.
        #expect(layout.surface(expanded: true, wing: 170).contains(left))
        #expect(layout.surface(expanded: true, wing: 170).contains(right))
    }

    @Test(arguments: [CGFloat(0), 40, 146, 147, 220])
    func wholeClustersRespectCameraAndOuterClearance(width: CGFloat) throws {
        let wings = try #require(layout.wings(expanded: false, wing: 170))
        let left = StatusGutters.frame(size: CGSize(width: width, height: 17), in: wings.left, side: .left)
        let right = StatusGutters.frame(size: CGSize(width: width, height: 17), in: wings.right, side: .right)
        #expect((left != nil) == (width > 0 && width <= 146))
        #expect((right != nil) == (width > 0 && width <= 146))
        #expect(StatusGutters.frame(size: CGSize(width: 40, height: 38), in: wings.left, side: .left) == nil)
    }

    @Test func overflowStillSpillsWholeSegmentsBeforePlacement() throws {
        let shown = WingFit.fit(leading: [("cpu", 40.0)], trailing: [("weather", 70.0), ("ram", 40), ("timer", 40), ("too-wide", 200)],
                                maxWidth: 146, spacing: 6)
        #expect(shown.leading == ["timer", "cpu"])
        #expect(shown.trailing == ["weather", "ram"])
        let wings = try #require(layout.wings(expanded: false, wing: 144))
        #expect(StatusGutters.frame(size: CGSize(width: 86, height: 17), in: wings.left, side: .left)?.minX == 428)
        #expect(StatusGutters.frame(size: CGSize(width: 116, height: 17), in: wings.right, side: .right)?.maxX == 884)
    }

    @Test func idleAndExternalDisplaysKeepTheirOwnGeometry() {
        #expect(layout.surface(expanded: false).width == 204)
        let empty = layout.wings(expanded: false)!
        #expect(StatusGutters.frame(size: CGSize(width: 40, height: 17), in: empty.left, side: .left) == nil)
        let external = DisplayLayout(frame: CGRect(x: -1920, y: -100, width: 1920, height: 1080),
                                     visibleFrame: CGRect(x: -1920, y: -100, width: 1920, height: 1055), safeTop: 0, cameraGap: nil)
        #expect(external.wings(expanded: false, wing: 120) == nil)
        #expect(external.surface(expanded: false, wing: 120) == CGRect(x: -1034, y: 917, width: 148, height: 32))
    }

    @Test func clampedWingOmitsContentRatherThanEnteringCamera() throws {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let tiny = DisplayLayout(frame: frame, visibleFrame: frame, safeTop: 37,
                                 cameraGap: CGRect(x: 64, y: 203, width: 192, height: 37))
        let wings = try #require(tiny.wings(expanded: false, wing: 170))
        #expect(StatusGutters.frame(size: CGSize(width: 40, height: 17), in: wings.left, side: .left) == nil)
        #expect(StatusGutters.frame(size: CGSize(width: 40, height: 17), in: wings.right, side: .right) == nil)
    }
}
