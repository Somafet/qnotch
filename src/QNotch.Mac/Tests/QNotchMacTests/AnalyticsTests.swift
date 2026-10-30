import XCTest
@testable import QNotchMacCore
@testable import QNotchMac

private final class AnalyticsURLProtocol: URLProtocol {
    static var received: ((URLRequest) -> Void)?
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.received?(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AnalyticsTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func fixture(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tests/fixtures/analytics/" + name))) as? [String: Any])
    }
    func testNativeCatalogIsSubsetOfSharedContract() throws {
        let catalog = try fixture("catalog-v1.json")
        let modules = try XCTUnwrap(catalog["modules"] as? [String: [String]])
        XCTAssertEqual(catalog["event"] as? String, "qnotch_action")
        XCTAssertEqual(Set(catalog["surfaces"] as? [String] ?? []), AnalyticsCatalog.surfaces)
        XCTAssertTrue(AnalyticsCatalog.targets.isSubset(of: Set(catalog["targets"] as? [String] ?? [])))
        for (module, actions) in AnalyticsCatalog.actions {
            XCTAssertTrue(actions.isSubset(of: Set(modules[module] ?? [])), module)
        }
        XCTAssertFalse(AnalyticsCatalog.accepts(module: "notes", action: "private note text", surface: "ui"))
    }
    func testIdentityMatchesSharedSHA256Vectors() throws {
        let vectors = try XCTUnwrap(try fixture("identity-v1.json")["vectors"] as? [[String: String]])
        for vector in vectors { XCTAssertEqual(AnalyticsIdentity.hash(try XCTUnwrap(vector["raw"])), vector["sha256"]) }
    }
    func testConsentDefaultsAndLocalSetupIsolation() throws {
        let original = try JSONDecoder().decode(GeneralSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(original.shareUsageData)
        var general = original; general.shareUsageData = false
        XCTAssertFalse(try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(general)).shareUsageData)
        func snapshot(_ general: GeneralSettings) -> SetupCode.Snapshot {
            SetupCode.Snapshot(general: general, gameMode: GameModeSettings(), timer: TimerSettings(), weather: WeatherSettings(), notifications: NotificationSettings(), ai: AiSettings(), agents: AgentsSettings())
        }
        let local = snapshot(general)
        let imported = try SetupCode.read(SetupCode.export(local), current: snapshot(original), modules: [])
        XCTAssertTrue(imported.result.general.shareUsageData, "Import retains receiver's local consent")
    }
    func testIdentityIsPersistentAndProviderPrecedenceIsHashed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let install = try XCTUnwrap(AnalyticsIdentity.resolve(directory: directory, environment: [:], home: directory))
        XCTAssertEqual(install.source, "anonymous")
        XCTAssertEqual(install.installID, AnalyticsIdentity.resolve(directory: directory, environment: [:], home: directory)?.installID)
        try Data(#"{"tokens":{"account_id":"synthetic-codex"}}"#.utf8).write(to: directory.appendingPathComponent(".codex/auth.json"))
        try Data(#"{"userID":"synthetic-claude"}"#.utf8).write(to: directory.appendingPathComponent(".claude.json"))
        let provider = try XCTUnwrap(AnalyticsIdentity.resolve(directory: directory, environment: [:], home: directory))
        XCTAssertEqual(provider.source, "codex")
        XCTAssertEqual(provider.distinctID, AnalyticsIdentity.hash("synthetic-codex"))
        XCTAssertEqual(provider.installID, install.installID)
    }
    func testDisabledAndUnconfiguredNeverResolveIdentity() {
        let network = expectation(description: "no network"); network.isInverted = true
        AnalyticsURLProtocol.received = { _ in network.fulfill() }
        defer { AnalyticsURLProtocol.received = nil }
        let transport = URLSessionConfiguration.ephemeral; transport.protocolClasses = [AnalyticsURLProtocol.self]
        var clients: [ProductAnalytics] = []
        var resolutions = 0
        for (key, enabled) in [("", true), ("synthetic", false)] {
            let client = ProductAnalytics(configuration: .init(key: key), enabled: enabled, version: "test", session: URLSession(configuration: transport)) { resolutions += 1; return nil }
            clients.append(client)
            client.capture(module: "shell", action: "open_panel"); client.flush()
            XCTAssertEqual(client.bufferedCount, 0)
        }
        XCTAssertEqual(resolutions, 0)
        wait(for: [network], timeout: 0.1)
        withExtendedLifetime(clients) {}
    }
    func testPayloadHasOnlyApprovedPropertiesAndOptOutDropsQueue() throws {
        let sent = expectation(description: "batch")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AnalyticsURLProtocol.self]
        let session = URLSession(configuration: config)
        var captured: [String: Any]?
        AnalyticsURLProtocol.status = 200
        AnalyticsURLProtocol.received = { request in
            // URLProtocol may expose the body as a stream.
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
            }
            captured = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            sent.fulfill()
        }
        defer { AnalyticsURLProtocol.received = nil }
        let client = ProductAnalytics(configuration: .init(key: "synthetic"), enabled: true, version: "test", session: session) {
            AnalyticsIdentity(distinctID: String(repeating: "a", count: 64), installID: String(repeating: "b", count: 64), source: "anonymous")
        }
        client.capture(module: "shell", action: "select_tab", surface: "hotkey", target: "notes", enabled: true)
        client.flush()
        wait(for: [sent], timeout: 2)
        let events = try XCTUnwrap(captured?["batch"] as? [[String: Any]])
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["install_id", "identity_source", "schema_version", "platform", "app_version", "module", "action", "surface", "outcome", "$process_person_profile", "target", "enabled"])
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        XCTAssertEqual(properties["outcome"] as? String, "requested")
        XCTAssertEqual(properties["platform"] as? String, "macos")
        XCTAssertEqual(properties["target"] as? String, "notes")
        XCTAssertEqual(properties["enabled"] as? Bool, true)
        XCTAssertEqual(events.first?["distinct_id"] as? String, String(repeating: "a", count: 64))
        client.capture(module: "notes", action: "save")
        client.setEnabled(false)
        XCTAssertEqual(client.bufferedCount, 0)
        client.capture(module: "shell", action: "quit")
        XCTAssertEqual(client.bufferedCount, 0)
    }
    func testUnknownTargetsAndDiagnosticActionsCannotResolveIdentity() {
        var resolutions = 0
        let client = ProductAnalytics(configuration: .init(key: "synthetic"), enabled: true, version: "test") { resolutions += 1; return nil }
        client.capture(module: "shell", action: "select_tab", target: "private window title")
        XCTAssertEqual(client.bufferedCount, 0)
        let previous = Runtime.diagnostics, previousClient = Analytics.client
        defer { Runtime.diagnostics = previous; Analytics.client = previousClient }
        Analytics.client = client; Runtime.diagnostics = true
        Analytics.record("shell", "open_panel")
        XCTAssertEqual(client.bufferedCount, 0)
        XCTAssertEqual(resolutions, 0)
    }
    func testIdentityStagingIsBoundedAndOptOutInvalidatesResolution() {
        let began = expectation(description: "identity began")
        let release = DispatchSemaphore(value: 0)
        let client = ProductAnalytics(configuration: .init(key: "synthetic"), enabled: true, version: "test") {
            began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return AnalyticsIdentity(distinctID: "synthetic", installID: "synthetic", source: "anonymous")
        }
        for _ in 0..<1005 { client.capture(module: "notes", action: "save") }
        wait(for: [began], timeout: 2)
        XCTAssertEqual(client.bufferedCount, 1000)
        client.setEnabled(false)
        release.signal()
        XCTAssertEqual(client.bufferedCount, 0)
        client.capture(module: "shell", action: "quit")
        XCTAssertEqual(client.bufferedCount, 0)
    }

    func testTransient408RetriesWithStableEventUUID() {
        let retried = expectation(description: "retry")
        retried.expectedFulfillmentCount = 2
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AnalyticsURLProtocol.self]
        var ids: [String] = []
        AnalyticsURLProtocol.received = { request in
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
            }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let event = (root?["batch"] as? [[String: Any]])?.first
            ids.append(event?["uuid"] as? String ?? "missing")
            AnalyticsURLProtocol.status = ids.count == 1 ? 408 : 200
            retried.fulfill()
        }
        defer { AnalyticsURLProtocol.received = nil }
        let client = ProductAnalytics(configuration: .init(key: "synthetic"), enabled: true, version: "test", session: URLSession(configuration: config)) {
            AnalyticsIdentity(distinctID: String(repeating: "a", count: 64), installID: String(repeating: "b", count: 64), source: "anonymous")
        }
        client.capture(module: "notes", action: "save"); client.flush()
        wait(for: [retried], timeout: 5)
        client.setEnabled(false)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids.first, "missing")
        XCTAssertEqual(ids.first, ids.last)
    }

}
