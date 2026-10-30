import XCTest
import Darwin
@testable import QNotchMac
import QNotchMacCore

final class ConsumerTests: XCTestCase {
    func testSyntheticReadersDuplicatesSubagentsUnknownPricing() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/consumer")
        let quota = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("quota.json"))) as! [String: Any]
        guard case .ok(let windows, _, _, _) = ClaudeUsage.parse(usage: quota, tier: nil) else { return XCTFail("quota") }
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day_sonnet"])
        XCTAssertEqual(windows.map(\.durationSeconds), [18000, 604800])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subs = root.appendingPathComponent("session/subagents")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("session.jsonl")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("transcript.jsonl"), to: transcript)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("subagent.jsonl"), to: subs.appendingPathComponent("agent.jsonl"))
        let reader = TranscriptUsage(); reader.read(transcript); reader.read(transcript)
        let total = reader.days.values.reduce(AgentUsage(), +)
        XCTAssertEqual(total.tokens, 46) // 15 replacement + 23 unknown + 8 subagent
        XCTAssertTrue(total.unpriced)
    }
    func testUnavailableReadAndOversizedSnapshot() throws {
        let reader = TranscriptUsage()
        reader.read(URL(fileURLWithPath: "/does-not-exist/synthetic.jsonl"))
        XCTAssertFalse(reader.readComplete)
        let registry = ConsumerRegistry(); registry.status = { _ in "ready" }
        registry.capture["agents"] = { _ in ["large": String(repeating: "x", count: ConsumerWire.responseLimit + 1)] }
        let object = try registry.reply(ConsumerRequest(command: "agents"))
        XCTAssertGreaterThan(ConsumerJSON.encode(object).count, ConsumerWire.responseLimit)
        let failure = ConsumerFailure("size_limit").data
        XCTAssertLessThan(failure.count, ConsumerWire.responseLimit)
    }
    func testArgumentsAndSanitization() throws {
        for args in [["usage", "--provider", "other"], ["agents", "--account", "x"], ["usage", "--json", "--json"], ["usage", "--wat"], ["usage", "--account"]] {
            XCTAssertThrowsError(try ConsumerRequest.parse(args))
        }
        let (request, root) = try ConsumerRequest.parse(["usage", "--json", "--details", "--provider", "claude", "--data-dir", "/tmp/test"])
        XCTAssertTrue(request.details); XCTAssertEqual(root, "/tmp/test")
        XCTAssertEqual(ConsumerJSON.text("Café\n\u{202E}hello"), "Caféhello")
    }
    func testQuotaProjectionPrivacyExpiryAndOptionalCredits() {
        let now = Date()
        let result = UsageResult.ok(windows: [UsageWindow(label: "5-hour", usedPercent: 42, resetsAt: now.addingTimeInterval(50), id: "five_hour", durationSeconds: 18000)], plan: "Max", asOf: now.addingTimeInterval(-100), banked: nil)
        let row = AiModule.consumerAccount(provider: "claude", id: "opaque", label: "private", enabled: true, result: result, checked: now, refreshing: false, details: false, now: now)
        XCTAssertEqual(row["status"] as? String, "ok"); XCTAssertNil(row["label"])
        XCTAssertNotEqual(row["checked_at"] as? String, row["observed_at"] as? String)
        XCTAssertEqual((row["banked_resets"] as? [String: Any])?["status"] as? String, "unknown")
        let expired = AiModule.consumerAccount(provider: "claude", id: "opaque", label: "private", enabled: true, result: result, checked: now, refreshing: false, details: true, now: now.addingTimeInterval(100))
        XCTAssertEqual(expired["status"] as? String, "unavailable")
        XCTAssertTrue((expired["windows"] as? [Any])!.isEmpty)
        for enabled in [true, false] {
            let pending = AiModule.consumerAccount(provider: "codex", id: "x", label: "x", enabled: enabled, result: nil, checked: nil, refreshing: false, details: false, now: now)
            XCTAssertEqual(pending["status"] as? String, enabled ? "pending" : "disabled")
        }
    }
    func testMultipleAccountsIgnoreUISelectionAndStableIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try ConsumerIdentity(directory: root)
        XCTAssertEqual(identity.id("account"), try ConsumerIdentity(directory: root).id("account"))
        let module = AiModule(accounts: [ClaudeAccount(path: "/synthetic/a", folderName: "A", isDefault: false), ClaudeAccount(path: "/synthetic/b", folderName: "B", isDefault: false)])
        let all = try module.consumerUsage(ConsumerRequest(command: "usage", provider: "claude"), identity: identity)["accounts"] as! [[String: Any]]
        XCTAssertEqual(all.count, 2)
        let id = all[1]["account_id"] as! String
        let filtered = try module.consumerUsage(ConsumerRequest(command: "usage", provider: "claude", account: id), identity: identity)["accounts"] as! [[String: Any]]
        XCTAssertEqual(filtered.count, 1)
        XCTAssertThrowsError(try module.consumerUsage(ConsumerRequest(command: "usage", provider: "codex", account: id), identity: identity))
    }
    func testTransportPermissionsBoundsIsolationAndShutdown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = try ApplicationInstance.acquire(directory: root)
        defer { instance.close() }
        let registry = ConsumerRegistry(); registry.status = { _ in "disabled" }
        let path = try ConsumerWire.path(directory: root)
        let service = try ConsumerService(path: path, registry: registry)
        var info = stat(); XCTAssertEqual(lstat(path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let done = expectation(description: "parallel cached queries")
        DispatchQueue.global().async {
            for _ in 0..<8 {
                do {
                    let data = try ConsumerWire.query(ConsumerRequest(command: "agents"), directory: root)
                    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    XCTAssertEqual(object["module_status"] as? String, "disabled")
                } catch { XCTFail("\(error)") }
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        registry.status = { _ in "ready" }
        registry.capture["agents"] = { _ in ["large": String(repeating: "x", count: ConsumerWire.responseLimit + 1)] }
        let oversized = expectation(description: "oversized snapshot refused on wire")
        DispatchQueue.global().async {
            do {
                let data = try ConsumerWire.query(ConsumerRequest(command: "agents"), directory: root)
                let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "size_limit")
            } catch { XCTFail("\(error)") }
            oversized.fulfill()
        }
        wait(for: [oversized], timeout: 3)
        service.close(); XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try ConsumerWire.query(ConsumerRequest(command: "usage"), directory: root))
        let pair = UnsafeMutablePointer<Int32>.allocate(capacity: 2); defer { pair.deallocate() }
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        ConsumerWire.prepare(pair[0]); ConsumerWire.prepare(pair[1])
        try ConsumerWire.send(pair[0], data: Data(repeating: 65, count: 4097), deadline: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertThrowsError(try ConsumerWire.readLine(pair[1], limit: 4096, deadline: ProcessInfo.processInfo.systemUptime + 1))
        XCTAssertThrowsError(try ConsumerWire.readLine(pair[1], limit: 4096, deadline: ProcessInfo.processInfo.systemUptime + 0.02))
    }
}
