import XCTest
@testable import CalculatorEngine

/// The bundled help, interface strings and share viewer are the Windows engine's assets byte for byte, and are written out on demand.
/// Not a port of a C# test class.
final class CalculatorAssetsTests: XCTestCase {
    private let directory = TestFiles.temporary("Calc-assets-tests")
    override func tearDown() { TestFiles.delete(directory) }

    func testBundledAssetsMatchTheWindowsEngine() throws {
        let engine = Fixtures.repositoryRoot.appendingPathComponent("src/QNotch.Calculator.Engine/Assets").path
        for name in ["Help.html", "UiStrings.json"] + CalculatorAssets.viewerFiles.map({ "ShareViewer/" + $0 }) {
            XCTAssertEqual(try TestFiles.readBytes(engine + "/" + name), try CalculatorAssets.bytes("Assets/" + name), name)
        }
        XCTAssertEqual(try TestFiles.readBytes(engine + "/UiStrings.json"), try CalculatorAssets.uiStrings)
        let notices = try CalculatorAssets.bytes("THIRD-PARTY-NOTICES.txt").utf8Text
        XCTAssertTrue(notices.contains("Noda Time 3.3.7") && notices.contains("Apache License"))
        XCTAssertFalse(notices.contains("AvalonEdit")) // The Mac engine ships no editor component.
    }

    /// In the packaged app SwiftPM's `Bundle.module` looks beside QNotch.app and then in the build machine's .build folder, so it
    /// traps on a user's Mac (opening the Calculator tab crashed 0.7.0). Tests can't see that because the .build folder exists here,
    /// so check that every resource read goes through `CalculatorEngine.bundle`, which also looks in Contents/Resources.
    func testResourcesAreReadThroughTheAppAwareBundle() throws {
        let sources = Fixtures.repositoryRoot.appendingPathComponent("src/QNotch.Mac/Calculator/Sources/CalculatorEngine")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let users = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("Bundle.module") }.map(\.lastPathComponent)
        XCTAssertEqual(["Engine.swift"], users, "Only CalculatorEngine.bundle may fall back to Bundle.module")
    }

    func testAssetsAreWrittenOnDemandAndOnlyWhenChanged() throws {
        let viewer = try CalculatorAssets.writeShareViewer(directory)
        XCTAssertEqual(TestFiles.path(directory, "ShareViewer", "index.html"), viewer)
        for file in CalculatorAssets.viewerFiles { XCTAssertEqual(try CalculatorAssets.bytes("Assets/ShareViewer/" + file), try TestFiles.readBytes(TestFiles.path(directory, "ShareViewer", file))) }
        let help = try CalculatorAssets.writeHelp(directory), notices = try CalculatorAssets.writeNotices(directory)
        XCTAssertEqual(try CalculatorAssets.bytes("Assets/Help.html"), try TestFiles.readBytes(help))
        XCTAssertEqual(try CalculatorAssets.bytes("THIRD-PARTY-NOTICES.txt"), try TestFiles.readBytes(notices))
        let stamp = DateTimeOffset(2026, 1, 1).utcTicks
        try NetFile.setLastWriteTicks(help, stamp)
        _ = try CalculatorAssets.writeHelp(directory)
        XCTAssertEqual(stamp, NetFile.info(help).lastWriteTicks) // Unchanged content is not rewritten.
        try TestFiles.writeText(help, "stale")
        _ = try CalculatorAssets.writeHelp(directory)
        XCTAssertEqual(try CalculatorAssets.bytes("Assets/Help.html"), try TestFiles.readBytes(help))
        XCTAssertTrue(TestFiles.files(directory, "*.tmp").isEmpty)
    }
}
