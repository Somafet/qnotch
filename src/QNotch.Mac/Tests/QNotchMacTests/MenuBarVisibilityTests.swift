import Darwin
import Foundation
import Testing
import QNotchMacCore
@testable import QNotchMac

struct MenuBarVisibilityTests {
    @Test(arguments: ["{}", #"{"timerEnabled":false}"#, #"{"disabledModules":["search"]}"#])
    func existingSettingsKeepVisibleDefault(_ json: String) throws {
        #expect(GeneralSettings().showMenuBarIcon)
        #expect(try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8)).showMenuBarIcon)
    }

    @Test func visibilitySurvivesSaveAndRelaunchWithoutChangingOtherPreferences() throws {
        let root = rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(directory: root)
        var settings = GeneralSettings()
        settings.pinned = true
        settings.disabledModules = ["search", "timer"]
        settings.showMenuBarIcon = false
        #expect(store.save("general", settings))
        #expect(SettingsStore(directory: root).load("general", default: GeneralSettings()) == settings)
        settings.showMenuBarIcon = true
        #expect(store.save("general", settings))
        #expect(SettingsStore(directory: root).load("general", default: GeneralSettings()) == settings)
    }

    @Test func lockAndRecoveryAreScopedToTheSameDirectoryIncludingAliasesAndLongPaths() throws {
        let root = rootURL().appendingPathComponent(String(repeating: "nested", count: 24))
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let first = try ApplicationInstance.acquire(directory: root)
        defer { first.close() }
        #expect(first.recoveryPath.utf8.count < 104)
        #expect(throws: ApplicationInstance.Failure.alreadyRunning) { try ApplicationInstance.acquire(directory: root) }
        let alias = root.deletingLastPathComponent().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        #expect(throws: ApplicationInstance.Failure.alreadyRunning) { try ApplicationInstance.acquire(directory: alias) }
        let other = try ApplicationInstance.acquire(directory: root.appendingPathComponent("other"))
        #expect(other.recoveryPath != first.recoveryPath)
        other.close()
        first.close()
        let nextLaunch = try ApplicationInstance.acquire(directory: root)
        #expect(nextLaunch.recoveryPath == first.recoveryPath)
        nextLaunch.close()
    }

    @Test @MainActor func recoveryOnlyOpensSettingsAndNeverEnablesDebugControl() async throws {
        let root = rootURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = try ApplicationInstance.acquire(directory: root)
        defer { instance.close() }
        var opens = 0
        try instance.startRecovery { opens += 1 }
        var info = stat()
        #expect(lstat(instance.recoveryPath, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == geteuid())
        #expect(DebugChannel.current == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("debug.sock").path))
        for command in DebugProtocol.commands where command != "settings" {
            let reply = try await ask(["cmd": command], path: instance.recoveryPath)
            #expect(reply["ok"] as? Bool == false)
        }
        #expect(try await ask(["cmd": "settings", "args": ["section": "about"]], path: instance.recoveryPath)["ok"] as? Bool == false)
        #expect(opens == 0)
        #expect(try await ask(["cmd": "settings"], path: instance.recoveryPath)["ok"] as? Bool == true)
        #expect(opens == 1)
        let delivered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: ApplicationInstance.requestSettings(directory: root, wait: 0)) }
        }
        #expect(delivered)
        #expect(opens == 2)
        instance.close()
        #expect(!FileManager.default.fileExists(atPath: instance.recoveryPath))
        #expect(!ApplicationInstance.requestSettings(directory: root, wait: 0))
    }

    @Test func invalidLockCannotBypassSingleInstanceProtection() throws {
        let root = rootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("instance.lock"), withDestinationURL: root.appendingPathComponent("elsewhere"))
        #expect(throws: ApplicationInstance.Failure.unavailable) { try ApplicationInstance.acquire(directory: root) }
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
        return try #require(JSONSerialization.jsonObject(with: response.get()) as? [String: Any])
    }
}
