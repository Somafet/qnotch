import XCTest
import AppKit
import QNotchMacCore
@testable import QNotchMac

final class NotificationMuteTests: XCTestCase {
    private final class Shell: ModuleShell {
        var peeks: [PeekHandle] = []
        var opens = 0
        var actionChanges = 0
        func peek(symbol: String, tint: NSColor, leading: String, trailing: String, seconds: TimeInterval?) -> PeekHandle? {
            let handle = PeekHandle { _ in }
            peeks.append(handle)
            return handle
        }
        func tryOpenPanel(tab: String, linger: TimeInterval) -> Bool { opens += 1; return true }
        func actionsChanged() { actionChanges += 1 }
        func segmentsChanged() {}
        func selectTab(_ id: String) {}
        func openSettings() {}
        func openSettings(section: String) {}
        func holdOpen() -> AnyObject { NSObject() }
        func acceptFileDrops(entered: @escaping () -> Void, dropped: @escaping ([URL]) -> Void) {}
        func closePanel() {}
        func dismissPanel() {}
    }

    private func withModule(_ body: (NotificationsModule, Shell, ModuleRegistries, SettingsStore) throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qm77-" + UUID().uuidString)
        let store = SettingsStore(directory: directory)
        var settings = NotificationSettings()
        settings.quietDuringCalls = false // No hardware listeners in the test.
        settings.httpEnabled = false
        store.save("notifications", settings)
        let shell = Shell(), registries = ModuleRegistries(), module = NotificationsModule()
        registries.owner = "notifications"
        module.initialize(ModuleContext(settings: store, registries: registries, shell: shell))
        registries.owner = nil
        defer {
            module.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        try body(module, shell, registries, store)
    }

    private func post(_ module: NotificationsModule, _ json: String, reply: @escaping (Data) -> Void = { _ in }) -> NotifyExchange {
        let exchange = NotifyExchange(send: reply)
        module.handle(Data(json.utf8), exchange: exchange)
        return exchange
    }

    func testMuteEndsCurrentPeekAndKeepsNewErrorsUnreadWithoutOpening() {
        withModule { module, shell, _, _ in
            _ = post(module, #"{"id":"first","app":"one","title":"First"}"#)
            XCTAssertEqual(shell.peeks.count, 1)
            module.toggleMute()
            XCTAssertTrue(shell.peeks[0].ended)
            _ = post(module, #"{"id":"error","app":"two","title":"Failed","level":"error","actions":[{"label":"Show","focusPid":1}]}"#)
            XCTAssertEqual(module.items.count, 2)
            XCTAssertEqual(module.unread, 2)
            XCTAssertEqual(shell.peeks.count, 1)
            XCTAssertEqual(shell.opens, 0)
            module.setVisibility(panel: false, activeTab: "home")
            XCTAssertEqual(shell.peeks.count, 1)
            module.toggleMute()
            XCTAssertEqual(shell.peeks.count, 1, "No stale transient replay")
            _ = post(module, #"{"id":"new","app":"three","title":"New error","level":"error"}"#)
            XCTAssertEqual(shell.peeks.count, 2)
            XCTAssertEqual(shell.opens, 1)
        }
    }

    func testWaitingNotificationStaysAnswerableAndUnmuteRestoresPendingPeek() throws {
        try withModule { module, shell, _, _ in
            module.toggleMute()
            var reply: [String: Any] = [:]
            let exchange = post(module, #"{"id":"wait","app":"CI","title":"Deploy?","wait":true,"actions":[{"id":"yes","label":"Approve"}]}"#) {
                reply = (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:]
            }
            XCTAssertFalse(exchange.isAnswered)
            XCTAssertEqual(shell.peeks.count, 0)
            let note = try XCTUnwrap(module.items.first)
            XCTAssertTrue(note.pending)
            module.toggleMute()
            XCTAssertEqual(shell.peeks.count, 1)
            module.toggleMute()
            XCTAssertTrue(shell.peeks[0].ended)
            module.invoke(try XCTUnwrap(note.actions.first), on: note)
            XCTAssertEqual(reply["result"] as? String, "clicked")
            XCTAssertEqual(reply["action"] as? String, "yes")
            XCTAssertFalse(note.pending)
            XCTAssertEqual(module.items.count, 1)
        }
    }

    func testMutePreservesDismissAndStopReplies() {
        withModule { module, _, _, _ in
            module.toggleMute()
            var replies: [String] = []
            for id in ["dismiss", "stop"] {
                _ = post(module, "{\"id\":\"\(id)\",\"title\":\"Wait\",\"wait\":true}") {
                    let reply = (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
                    replies.append(reply?["result"] as? String ?? "")
                }
            }
            _ = post(module, #"{"op":"dismiss","id":"dismiss"}"#)
            XCTAssertEqual(replies, ["dismissed"])
            module.stop()
            XCTAssertEqual(replies, ["dismissed", "timeout"])
        }
    }

    func testMutedWaitStillTimesOut() {
        withModule { module, shell, _, _ in
            module.toggleMute()
            let timedOut = expectation(description: "muted wait timeout")
            _ = post(module, #"{"id":"timeout","title":"Wait","wait":true,"timeout":0.02}"#) {
                let reply = (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
                XCTAssertEqual(reply?["result"] as? String, "timeout")
                timedOut.fulfill()
            }
            wait(for: [timedOut], timeout: 2)
            XCTAssertFalse(module.items[0].pending)
            XCTAssertEqual(shell.peeks.count, 0)
        }
    }

    func testLiveButtonsMenuRegistrationSegmentAndPersistence() throws {
        try withModule { module, shell, registry, store in
            let button = module.makeMuteButton()
            let other = module.makeMuteButton()
            let settingsButton = module.makeSettingsMuteButton()
            let action = try XCTUnwrap(registry.menuActions.items.first)
            let segment = try XCTUnwrap(registry.segments.items.first?.makeView())
            XCTAssertTrue(segment.isHidden)
            XCTAssertFalse(action.isOn())
            button.performClick(nil)
            XCTAssertEqual(button.text, "Unmute")
            XCTAssertEqual(other.text, "Unmute")
            XCTAssertEqual(settingsButton.title, "Unmute")
            XCTAssertTrue(button.isSelectedLook)
            XCTAssertFalse(segment.isHidden)
            XCTAssertTrue(action.isOn())
            XCTAssertEqual(shell.actionChanges, 1)
            XCTAssertTrue(store.load("notifications", default: NotificationSettings()).manuallyMuted)
            let reloaded = NotificationsModule()
            reloaded.initialize(ModuleContext(settings: store, registries: ModuleRegistries(), shell: shell))
            XCTAssertTrue(reloaded.settings.manuallyMuted)
            reloaded.stop()
            action.run()
            XCTAssertEqual(button.text, "Mute")
            XCTAssertEqual(other.text, "Mute")
            XCTAssertEqual(settingsButton.title, "Mute")
            XCTAssertTrue(segment.isHidden)
            registry.removeAll(owner: "notifications")
            XCTAssertTrue(registry.menuActions.items.isEmpty)
            XCTAssertTrue(registry.segments.items.isEmpty)
        }
    }

    func testExistingPreferencesDefaultToUnmuted() throws {
        XCTAssertFalse(try JSONDecoder().decode(NotificationSettings.self, from: Data(#"{"toastSeconds":10}"#.utf8)).manuallyMuted)
    }
}
