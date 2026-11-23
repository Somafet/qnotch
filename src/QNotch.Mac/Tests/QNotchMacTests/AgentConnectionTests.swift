import XCTest
import QNotchMacCore

/// Connecting writes hooks; it does not mean events arrive. Whether one has, per agent kind, and what each place says about it.
final class AgentConnectionTests: XCTestCase {
    func testSeenIsSetOnAnEventAndClearedOnConnectAndDisconnect() {
        var settings = AgentsSettings()
        XCTAssertTrue(settings.seen.isEmpty, "a new install has seen nothing")
        // A hook arrives: set once. A second hook of the same kind changes nothing, so nothing is saved.
        XCTAssertTrue(settings.markSeen(.claude, true))
        XCTAssertFalse(settings.markSeen(.claude, true))
        XCTAssertEqual(settings.seen, ["claude"], "per kind: Codex has not been heard from")
        XCTAssertTrue(settings.markSeen(.codex, true))
        // Connect or Disconnect of one kind clears that kind only, and clearing what is not set changes nothing.
        XCTAssertTrue(settings.markSeen(.claude, false))
        XCTAssertFalse(settings.markSeen(.claude, false))
        XCTAssertEqual(settings.seen, ["codex"])
    }

    func testSeenIsSavedWithTheSettingsButNeverTravelsInSetupCodes() throws {
        var settings = AgentsSettings()
        settings.markSeen(.codex, true)
        let saved = try JSONDecoder().decode(AgentsSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.seen, ["codex"])
        XCTAssertTrue(try JSONDecoder().decode(AgentsSettings.self, from: Data(#"{"soundDone":false}"#.utf8)).seen.isEmpty, "a file from before it exists reads as nothing seen")
        var snapshot = SetupCode.Snapshot(general: GeneralSettings(), gameMode: GameModeSettings(), timer: TimerSettings(), weather: WeatherSettings(),
                                          notifications: NotificationSettings(), ai: AiSettings(), agents: settings)
        let code = SetupCode.export(snapshot)
        snapshot.agents = AgentsSettings()
        let plan = try SetupCode.read(code, current: snapshot, modules: [])
        XCTAssertTrue(plan.result.agents.seen.isEmpty, "applying someone else's code starts every connection as waiting")
    }

    func testAConnectedFileIsWaitingUntilAnEventArrives() {
        XCTAssertEqual(AgentConnectionText.connected(.claude, seen: false).text, "Hooks added. Waiting for the first event: start a new Claude Code session.")
        XCTAssertEqual(AgentConnectionText.connected(.codex, seen: false).text,
                       "Hooks added. Codex runs them once you trust them: /hooks in the CLI, or Settings, Hooks in the Codex app.")
        XCTAssertFalse(AgentConnectionText.connected(.claude, seen: false).receiving, "waiting is the warning color")
        for kind in [AgentHookFile.Kind.claude, .codex] {
            let line = AgentConnectionText.connected(kind, seen: true)
            XCTAssertEqual(line.text, "Connected. Receiving events.")
            XCTAssertTrue(line.receiving, "receiving is the success color")
        }
        XCTAssertEqual(AgentConnectionText.waiting([.claude, .codex]),
                       "Hooks added. Waiting for the first event: start a new Claude Code session. Codex runs them once you trust them: /hooks in the CLI, or Settings, Hooks in the Codex app.")
    }

    func testTheEmptyAgentsTabHasThreeCases() {
        XCTAssertEqual(AgentConnectionText.empty(connected: []).title, "No agents running")
        XCTAssertEqual(AgentConnectionText.empty(connected: []).detail, "Connect Claude Code or Codex in Settings, Agents.")
        // Connected, and every connected kind still waiting: it says what each is waiting for, once per kind.
        let waiting = AgentConnectionText.empty(connected: [(.claude, false)])
        XCTAssertEqual(waiting.title, "Waiting for the first event")
        XCTAssertEqual(waiting.detail, "Start a new Claude Code session.")
        XCTAssertEqual(AgentConnectionText.empty(connected: [(.codex, false)]).detail, "Trust the hooks in Codex: /hooks in the CLI, or Settings, Hooks in the Codex app.")
        let both = AgentConnectionText.empty(connected: [(.codex, false), (.claude, false), (.claude, false)])
        XCTAssertEqual(both.title, "Waiting for the first event")
        XCTAssertEqual(both.detail, "Start a new Claude Code session. Trust the hooks in Codex: /hooks in the CLI, or Settings, Hooks in the Codex app.")
        // One kind has delivered an event: the other may still wait, the tab is simply empty.
        for connected in [[(AgentHookFile.Kind.claude, true)], [(.claude, false), (.codex, true)]] {
            let idle = AgentConnectionText.empty(connected: connected)
            XCTAssertEqual(idle.title, "No agents running")
            XCTAssertEqual(idle.detail, "Sessions appear here when Claude Code or Codex is working.")
        }
    }

    func testKindsAreTheCatalogTargetsAndTheNamesHookEventsUse() throws {
        XCTAssertEqual(AgentHookFile.Kind.claude.target, "agents_claude")
        XCTAssertEqual(AgentHookFile.Kind.codex.target, "agents_codex")
        XCTAssertTrue(["agents_claude", "agents_codex"].allSatisfy(AnalyticsCatalog.targets.contains))
        XCTAssertEqual(AgentHookFile.Kind(rawValue: "claude"), .claude)
        XCTAssertEqual(AgentHookFile.Kind(rawValue: "codex"), .codex)
        XCTAssertNil(AgentHookFile.Kind(rawValue: "gemini"), "an unknown agent is never remembered")
    }
}
