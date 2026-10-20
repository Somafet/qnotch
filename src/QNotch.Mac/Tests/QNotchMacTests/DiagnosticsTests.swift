import XCTest
import AppKit
import QNotchMacCore
@testable import QNotchMac

final class DiagnosticsTests: XCTestCase {
    func testModesTakeTheirDirectory() {
        let snapshot = DiagnosticOptions(arguments: ["QNotch", "--snapshot", "/tmp/out", "--only", "tab-*"], environment: [:])
        XCTAssertEqual(snapshot.mode, .snapshot)
        XCTAssertEqual(snapshot.output, "/tmp/out")
        XCTAssertNil(snapshot.problem)
        // The older spelling still works.
        let smoke = DiagnosticOptions(arguments: ["QNotch", "--smoke-test", "--data-dir", "/tmp/data", "--output", "/tmp/smoke"], environment: [:])
        XCTAssertEqual(smoke.mode, .smoke)
        XCTAssertEqual(smoke.output, "/tmp/smoke")
        XCTAssertEqual(smoke.dataDirectory, "/tmp/data")
        XCTAssertNotNil(DiagnosticOptions(arguments: ["QNotch", "--measure"], environment: [:]).problem)
        XCTAssertNotNil(DiagnosticOptions(arguments: ["QNotch", "--snapshot", "--appearance", "dark"], environment: [:]).problem)
        let normal = DiagnosticOptions(arguments: ["QNotch"], environment: [:])
        XCTAssertNil(normal.mode)
        XCTAssertNil(normal.output)
        XCTAssertNil(normal.problem)
    }

    func testUnnamedControls() {
        let outline = """
        "Timer"
        [Button] "Start" #timer-start
        [Button] #timer-reset
          [Toggle] checked
        [Progress] 40 of 100
        [Field] "Search" value="[x]"
        "[Button]"

        """
        XCTAssertEqual(Outline.unnamedControls(in: outline), ["[Button] #timer-reset", "[Toggle] checked"])
        XCTAssertEqual(Outline.unnamedControls(in: ""), [])
    }

    func testPerformanceLimits() {
        let quiet = PerformanceLimits.check(cpuPercent: 0.0012, drawCallbacks: 0, residentBytes: 70 << 20)
        XCTAssertEqual(quiet.map(\.name), ["cpu_percent_one_core", "app_draw_callbacks_delta", "resident_bytes_end"])
        XCTAssertTrue(quiet.allSatisfy(\.ok))
        let busy = PerformanceLimits.check(cpuPercent: 0.2, drawCallbacks: 3, residentBytes: 81 << 20, prefix: "stats_wings_interval.")
        XCTAssertEqual(busy.map(\.ok), [false, false, false])
        XCTAssertEqual(busy[0].name, "stats_wings_interval.cpu_percent_one_core")
        XCTAssertTrue(PerformanceLimits.check(cpuPercent: 0.1, drawCallbacks: 0, residentBytes: 80 << 20).allSatisfy(\.ok))
        XCTAssertFalse(PerformanceLimit(name: "x", limit: 1, measured: .nan).ok)
        XCTAssertEqual(busy[1].json["measured"] as? Double, 3)
    }

    func testPNGsAreTwiceTheSizeAndOpaqueOverABackground() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 12))
        let plain = try XCTUnwrap(NSBitmapImageRep(data: try ShellController.png(of: view)))
        XCTAssertEqual(plain.pixelsWide, 60)
        XCTAssertEqual(plain.pixelsHigh, 24)
        XCTAssertEqual(plain.size, NSSize(width: 30, height: 12))
        XCTAssertEqual(plain.colorAt(x: 5, y: 5)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        let filled = try XCTUnwrap(NSBitmapImageRep(data: try ShellController.png(of: view, background: .red)))
        XCTAssertEqual(filled.pixelsWide, 60)
        XCTAssertEqual(filled.colorAt(x: 5, y: 5)?.alphaComponent ?? 0, 1, accuracy: 0.01)
    }
}
