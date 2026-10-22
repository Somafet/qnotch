import Darwin
import Foundation
import XCTest
import QNotchMacCore
@testable import QNotchMac

final class MenuBarVisibilityTests: XCTestCase {
    func testEmptySettingsKeepVisibleDefault() throws {
        try assertVisibleDefault("{}")
    }

    func testLegacyTimerSettingsKeepVisibleDefault() throws {
        try assertVisibleDefault(#"{"timerEnabled":false}"#)
    }

    func testDisabledSearchSettingsKeepVisibleDefault() throws {
        try assertVisibleDefault(#"{"disabledModules":["search"]}"#)
    }

    func testVisibilitySurvivesSaveAndRelaunchWithoutChangingOtherPreferences() throws {
        let root = rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(directory: root)
        var settings = GeneralSettings()
        settings.pinned = true
        settings.disabledModules = ["search", "timer"]
        settings.hoverOpensSegment = true
        settings.cardSizes = ["media": 1, "weather": 2]
        settings.showMenuBarIcon = false
        XCTAssertTrue(store.save("general", settings))
        XCTAssertEqual(SettingsStore(directory: root).load("general", default: GeneralSettings()), settings)
        settings.showMenuBarIcon = true
        XCTAssertTrue(store.save("general", settings))
        XCTAssertEqual(SettingsStore(directory: root).load("general", default: GeneralSettings()), settings)
    }

    func testLockAndRecoveryAreScopedToTheSameDirectoryIncludingAliasesAndLongPaths() throws {
        let root = rootURL().appendingPathComponent(String(repeating: "nested", count: 24))
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let first = try ApplicationInstance.acquire(directory: root)
        defer { first.close() }
        XCTAssertLessThan(first.recoveryPath.utf8.count, 104)
        XCTAssertThrowsError(try ApplicationInstance.acquire(directory: root)) { error in
            XCTAssertEqual(error as? ApplicationInstance.Failure, .alreadyRunning)
        }
        let alias = root.deletingLastPathComponent().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try ApplicationInstance.acquire(directory: alias)) { error in
            XCTAssertEqual(error as? ApplicationInstance.Failure, .alreadyRunning)
        }
        let other = try ApplicationInstance.acquire(directory: root.appendingPathComponent("other"))
        XCTAssertNotEqual(other.recoveryPath, first.recoveryPath)
        other.close()
        first.close()
        let nextLaunch = try ApplicationInstance.acquire(directory: root)
        XCTAssertEqual(nextLaunch.recoveryPath, first.recoveryPath)
        nextLaunch.close()
    }

    @MainActor func testRecoveryOnlyOpensSettingsAndNeverEnablesDebugControl() async throws {
        let root = rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = try ApplicationInstance.acquire(directory: root)
        defer { instance.close() }
        var opens = 0
        try instance.startRecovery { opens += 1 }
        var info = stat()
        XCTAssertEqual(lstat(instance.recoveryPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(info.st_uid, geteuid())
        XCTAssertNil(DebugChannel.current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("debug.sock").path))
        for command in DebugProtocol.commands where command != "settings" {
            let reply = try await ask(["cmd": command], path: instance.recoveryPath)
            XCTAssertEqual(reply["ok"] as? Bool, false, command)
        }
        let withArguments = try await ask(["cmd": "settings", "args": ["section": "about"]], path: instance.recoveryPath)
        XCTAssertEqual(withArguments["ok"] as? Bool, false)
        XCTAssertEqual(opens, 0)
        let settings = try await ask(["cmd": "settings"], path: instance.recoveryPath)
        XCTAssertEqual(settings["ok"] as? Bool, true)
        XCTAssertEqual(opens, 1)
        let delivered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: ApplicationInstance.requestSettings(directory: root, wait: 0)) }
        }
        XCTAssertTrue(delivered)
        XCTAssertEqual(opens, 2)
        instance.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: instance.recoveryPath))
        XCTAssertFalse(ApplicationInstance.requestSettings(directory: root, wait: 0))
    }

    func testInvalidLockCannotBypassSingleInstanceProtection() throws {
        let root = rootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("instance.lock"), withDestinationURL: root.appendingPathComponent("elsewhere"))
        XCTAssertThrowsError(try ApplicationInstance.acquire(directory: root)) { error in
            XCTAssertEqual(error as? ApplicationInstance.Failure, .unavailable)
        }
    }

    private func assertVisibleDefault(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(GeneralSettings().showMenuBarIcon, file: file, line: line)
        let settings = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.showMenuBarIcon, json, file: file, line: line)
    }

    private func rootURL() -> URL {
        // Kept beside the package build output, never in the user's production data directory.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/menu-bar-tests/\(UUID().uuidString)", isDirectory: true)
    }

    private func ask(_ request: [String: Any], path: String) async throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        let response: Result<Data, DebugClient.Failure> = await withCheckedContinuation { continuation in
            let line = data
            DispatchQueue.global().async { continuation.resume(returning: DebugClient.send(line, to: path, timeout: 2)) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.get()) as? [String: Any])
    }
}
