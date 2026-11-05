import XCTest
import AppKit
import Darwin
@testable import QNotchMac
@testable import QNotchMacCore

final class TaildropTests: XCTestCase {
    // MARK: Parsing

    func testTargetsPreferComputedNameSortOnlineFirstAndSkipMissingIds() throws {
        let json = #"""
        [
          {"Node":{"StableID":"n1","Name":"zeta.example-tailnet.ts.net.","ComputedName":"","Hostinfo":{"OS":"linux"},"Online":false}},
          {"Node":{"StableID":"n2","Name":"beta-phone.example-tailnet.ts.net.","ComputedName":"pixel-8","Hostinfo":{"OS":"android"},"Online":true}},
          {"Node":{"StableID":"","Name":"nameless.example-tailnet.ts.net.","Online":true}},
          {"Node":{"Name":"no-id.example-tailnet.ts.net.","Online":true}},
          {"Node":{"StableID":"n3","Name":"alpha.example-tailnet.ts.net.","Hostinfo":{"OS":"windows"},"Online":true}},
          {"Node":{"StableID":"n4","Name":"","ComputedName":"","Online":true}},
          {"PeerAPIURL":"http://100.64.0.9:1234"}
        ]
        """#
        let targets = try TaildropJSON.targets(from: Data(json.utf8))
        XCTAssertEqual(targets.map(\.name), ["alpha", "n4", "pixel-8", "zeta"], "Online first, then by name; ComputedName wins, else the first MagicDNS label")
        XCTAssertEqual(targets.map(\.id), ["n3", "n4", "n2", "n1"])
        XCTAssertEqual(targets.last?.online, false)
        XCTAssertEqual(targets.first?.osLabel, "Windows")
        XCTAssertEqual(targets.first(where: { $0.id == "n2" })?.osLabel, "Android")
        XCTAssertEqual(try TaildropJSON.targets(from: Data("null".utf8)), [])
        XCTAssertEqual(try TaildropJSON.targets(from: Data("[]".utf8)), [])
        XCTAssertThrowsError(try TaildropJSON.targets(from: Data("{\"error\":1}".utf8)))
    }

    func testMissingOnlineIsTreatedAsReachable() throws {
        let targets = try TaildropJSON.targets(from: Data(#"[{"Node":{"StableID":"a","ComputedName":"laptop","Hostinfo":{"OS":"macOS"}}}]"#.utf8))
        XCTAssertEqual(targets, [TaildropTarget(id: "a", name: "laptop", os: "macOS", online: true)])
        XCTAssertEqual(targets[0].osLabel, "macOS")
    }

    func testBackendStateMapping() throws {
        let cases: [(String, TaildropBackend, TaildropAvailability)] = [
            ("Running", .running, .ready), ("Stopped", .stopped, .disconnected), ("NeedsLogin", .needsLogin, .needsLogin),
            ("NeedsMachineAuth", .needsMachineAuth, .needsApproval), ("Starting", .starting, .starting), ("NoState", .starting, .starting),
            ("InUseOtherUser", .other("InUseOtherUser"), .other("InUseOtherUser"))
        ]
        for (raw, backend, availability) in cases {
            XCTAssertEqual(TaildropBackend(raw), backend, raw)
            XCTAssertEqual(TaildropAvailability(backend), availability, raw)
            XCTAssertEqual(try TaildropJSON.backend(from: Data(#"{"BackendState":"\#(raw)","Self":{}}"#.utf8)), backend)
        }
    }

    func testEveryUnavailableStateExplainsItselfWithAnAction() {
        let unavailable: [TaildropAvailability] = [.notInstalled, .notRunning, .appStoreEdition, .noAccess, .disconnected, .needsLogin, .needsApproval, .other("X")]
        for availability in unavailable {
            let notice = availability.notice(hasTargets: true)
            XCTAssertNotNil(notice?.action, "\(availability) needs a way out")
            XCTAssertFalse(notice?.title.isEmpty ?? true)
        }
        XCTAssertEqual(TaildropAvailability.notInstalled.notice(hasTargets: false)?.action, .download)
        XCTAssertEqual(TaildropAvailability.notRunning.notice(hasTargets: false)?.action, .openApp)
        XCTAssertNil(TaildropAvailability.ready.notice(hasTargets: true))
        XCTAssertEqual(TaildropAvailability.ready.notice(hasTargets: false)?.title, "No devices can receive files")
    }

    func testWaitingInboxParsesNullAndDropsUnsafeNames() throws {
        XCTAssertEqual(try TaildropJSON.waiting(from: Data("null".utf8)), [])
        let files = try TaildropJSON.waiting(from: Data(#"[{"Name":"report.pdf","Size":12},{"Name":"../escape.txt","Size":1},{"Name":"a/b","Size":1},{"Name":"Photo 2.jpg"}]"#.utf8))
        XCTAssertEqual(files, [TaildropWaitingFile(name: "Photo 2.jpg", size: 0), TaildropWaitingFile(name: "report.pdf", size: 12)])
    }

    // MARK: Names

    func testInboxNameSafety() {
        for name in ["holiday-photos.zip", "Résumé final.pdf", "notes", ".profile", "日本語.txt"] {
            XCTAssertTrue(TaildropNames.isSafeInboxName(name), name)
        }
        for name in ["", ".", "..", "../x", "a/b", "a\\b", "x:y", "a..b", "line\nbreak", "tab\there", " lead", "trail ", "nul\u{0}", String(repeating: "a", count: 256)] {
            XCTAssertFalse(TaildropNames.isSafeInboxName(name), name.debugDescription)
        }
    }

    func testPathEscaping() {
        XCTAssertEqual(TaildropNames.pathEscape("my file/100%.txt"), "my%20file%2F100%25.txt")
        XCTAssertEqual(TaildropNames.pathEscape("nAbC123-_.~"), "nAbC123-_.~")
        XCTAssertEqual(TaildropNames.pathEscape("é?#&"), "%C3%A9%3F%23%26")
    }

    func testFreeNameNeverOverwrites() {
        var taken: Set<String> = []
        XCTAssertEqual(TaildropNames.freeName("photo.jpg") { taken.contains($0) }, "photo.jpg")
        taken = ["photo.jpg", "photo (2).jpg"]
        XCTAssertEqual(TaildropNames.freeName("photo.jpg") { taken.contains($0) }, "photo (3).jpg")
        taken = ["README"]
        XCTAssertEqual(TaildropNames.freeName("README") { taken.contains($0) }, "README (2)")
    }

    // MARK: State and text

    func testStateIsSetOnlyWhenChanged() {
        var state = TaildropState()
        XCTAssertFalse(state.update(to: TaildropState()))
        XCTAssertTrue(state.update(to: .demo))
        XCTAssertFalse(state.update(to: .demo), "An unchanged refresh publishes nothing")
        var next = TaildropState.demo
        next.waiting = []
        XCTAssertTrue(state.update(to: next))
        XCTAssertNil(state.waitingText)
        XCTAssertEqual(TaildropState.demo.waitingText, "holiday-photos.zip is waiting in Taildrop")
        XCTAssertEqual(TaildropState.demo.onlineTargets.map(\.name), ["ipad-air", "pixel-8", "work-laptop"])
        XCTAssertEqual(TaildropState.demo.targets.last?.name, "home-nas")
    }

    func testTransferAndResultText() {
        let transfer = TaildropTransfer(deviceID: "a", deviceName: "pixel-8", fileName: "b.pdf", index: 2, count: 3, fraction: 0.456)
        XCTAssertEqual(transfer.text, "Sending b.pdf to pixel-8 · 2 of 3")
        XCTAssertEqual(transfer.tileText, "Sending · 45%")
        XCTAssertEqual(TaildropResult.sent(3, firstName: "a", to: "pixel-8", skippedFolders: 0).text, "Sent 3 files to pixel-8")
        XCTAssertEqual(TaildropResult.sent(1, firstName: "a.txt", to: "pixel-8", skippedFolders: 2).text, "Sent a.txt to pixel-8 · Skipped 2 folders")
        XCTAssertEqual(TaildropResult.failed("c", to: "nas", sent: 1, count: 2, reason: "offline").text, "Sent 1 of 2. Couldn't send c to nas: offline")
    }

    func testTaildropIsOptInAndInOneOnboardingGroup() throws {
        XCTAssertFalse(GeneralSettings().isEnabled("taildrop"))
        var settings = GeneralSettings()
        settings.setEnabled("taildrop", true)
        XCTAssertTrue(settings.isEnabled("taildrop"))
        XCTAssertEqual(ModuleList.all.filter { $0.id == "taildrop" }.count, 1)
        XCTAssertEqual(Onboarding.groups.filter { $0.modules.contains("taildrop") }.count, 1)
    }

    // MARK: Discovery

    func testDiscoveryFindsTheStandaloneAppsPortAndKey() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("ipnport").path, withDestinationPath: "53999")
        try Data("example-key\n".utf8).write(to: root.appendingPathComponent("sameuserproof-53999"))
        let paths = TaildropDiscovery.Paths(library: root.path, socket: root.appendingPathComponent("none.sock").path)
        XCTAssertEqual(TaildropDiscovery.discover(paths: paths, installed: { _ in false }), .endpoint(.tcp(port: 53999, token: "example-key")))

        let proof = root.appendingPathComponent("sameuserproof-53999").path
        chmod(proof, 0)
        defer { chmod(proof, 0o600) }
        if FileHandle(forReadingAtPath: proof) == nil {
            XCTAssertEqual(TaildropDiscovery.discover(paths: paths, installed: { _ in false }), .noAccess)
        }
    }

    func testDiscoveryFallsBackToSocketThenInstalledEdition() throws {
        let root = try temporaryDirectory()
        let paths = TaildropDiscovery.Paths(library: root.path, socket: root.appendingPathComponent("none.sock").path)
        XCTAssertEqual(TaildropDiscovery.discover(paths: paths, installed: { _ in false }), .notInstalled)
        XCTAssertEqual(TaildropDiscovery.discover(paths: paths, installed: { $0 == TaildropDiscovery.standaloneBundle }), .notRunning)
        XCTAssertEqual(TaildropDiscovery.discover(paths: paths, installed: { $0 == TaildropDiscovery.appStoreBundle }), .appStoreEdition)
        // A stale port link without its key file is not an endpoint.
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("ipnport").path, withDestinationPath: "53999")
        XCTAssertEqual(TaildropDiscovery.discover(paths: paths, installed: { _ in false }), .notInstalled)

        let server = try FakeLocalAPI { _ in (200, "{}") }
        defer { server.stop() }
        let socketPaths = TaildropDiscovery.Paths(library: root.path, socket: server.path)
        XCTAssertEqual(TaildropDiscovery.discover(paths: socketPaths, installed: { _ in false }), .endpoint(.unix(path: server.path)))
    }

    // MARK: Client against a fake LocalAPI

    func testClientGetSendsLocalAPIRequestAndReadsBody() throws {
        let server = try FakeLocalAPI { request in
            request.path == "/localapi/v0/status?peers=false" ? (200, #"{"BackendState":"Running"}"#) : (404, "not found\nmore")
        }
        defer { server.stop() }
        let client = TaildropClient(endpoint: .unix(path: server.path), timeout: 5)
        XCTAssertEqual(try TaildropJSON.backend(from: client.get("status?peers=false")), .running)
        XCTAssertEqual(server.requests.first?.method, "GET")
        XCTAssertEqual(server.requests.first?.headers["host"], "local-tailscaled.sock")
        XCTAssertNil(server.requests.first?.headers["authorization"], "Unix sockets need no key")
        XCTAssertThrowsError(try client.get("nope")) { error in
            XCTAssertEqual(error as? TaildropError, .http(404, "not found"))
        }
    }

    func testClientMapsMissingSocketToNotRunning() {
        let client = TaildropClient(endpoint: .unix(path: "/tmp/qnotch-no-such-\(UUID().uuidString.prefix(8)).sock"))
        XCTAssertThrowsError(try client.get("status")) { XCTAssertEqual($0 as? TaildropError, .notRunning) }
    }

    func testPutStreamsTheWholeFileWithLengthAndProgress() throws {
        let server = try FakeLocalAPI { _ in (200, "") }
        defer { server.stop() }
        let file = try temporaryDirectory().appendingPathComponent("payload.bin")
        let payload = Data((0..<700_000).map { UInt8($0 % 251) })
        try payload.write(to: file)
        var reported: [Int64] = []
        let client = TaildropClient(endpoint: .unix(path: server.path), timeout: 5)
        let path = "file-put/\(TaildropNames.pathEscape("node/1"))/\(TaildropNames.pathEscape("my file/100%.txt"))"
        try client.put(path, file: file, length: Int64(payload.count), cancel: TaildropCancellation()) { reported.append($0) }
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/localapi/v0/file-put/node%2F1/my%20file%2F100%25.txt")
        XCTAssertEqual(request.headers["content-length"], "\(payload.count)")
        XCTAssertEqual(request.body, payload)
        XCTAssertEqual(reported.last, Int64(payload.count))
        XCTAssertEqual(reported, reported.sorted())
    }

    func testCancelledPutStopsBeforeConnecting() throws {
        let server = try FakeLocalAPI { _ in (200, "") }
        defer { server.stop() }
        let file = try temporaryDirectory().appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: file)
        let cancel = TaildropCancellation()
        cancel.cancel()
        XCTAssertThrowsError(try TaildropClient(endpoint: .unix(path: server.path)).put("file-put/a/a.txt", file: file, length: 5, cancel: cancel) { _ in }) {
            XCTAssertEqual($0 as? TaildropError, .cancelled)
        }
    }

    func testProbeReadsStatusTargetsAndInboxThenKeepsTheListOnFailure() throws {
        var failTargets = false
        let lock = NSLock()
        let server = try FakeLocalAPI { request in
            switch request.path {
            case "/localapi/v0/status?peers=false": return (200, #"{"BackendState":"Running"}"#)
            case "/localapi/v0/file-targets":
                lock.lock(); defer { lock.unlock() }
                return failTargets ? (500, "boom") : (200, #"[{"Node":{"StableID":"x","ComputedName":"work-laptop","Hostinfo":{"OS":"windows"},"Online":true}}]"#)
            case "/localapi/v0/files/": return (200, "null")
            default: return (404, "")
            }
        }
        defer { server.stop() }
        let endpoint = TaildropEndpoint.unix(path: server.path)
        let ready = TaildropModule.probe(previous: TaildropState()) { .endpoint(endpoint) }
        XCTAssertEqual(ready.availability, .ready)
        XCTAssertEqual(ready.targets.map(\.name), ["work-laptop"])
        XCTAssertEqual(ready.waiting, [])
        XCTAssertNil(ready.message)
        lock.lock(); failTargets = true; lock.unlock()
        let failed = TaildropModule.probe(previous: ready) { .endpoint(endpoint) }
        XCTAssertEqual(failed.targets, ready.targets, "A failed refresh keeps the last list")
        XCTAssertEqual(failed.message, "Couldn't refresh: boom")
        XCTAssertEqual(TaildropModule.probe(previous: ready) { .notRunning }, TaildropState(availability: .notRunning))
    }

    func testProbeReportsStoppedBackendWithoutListingTargets() throws {
        let server = try FakeLocalAPI { request in
            request.path.hasPrefix("/localapi/v0/status") ? (200, #"{"BackendState":"Stopped"}"#) : (500, "unexpected")
        }
        defer { server.stop() }
        let state = TaildropModule.probe(previous: .demo) { .endpoint(.unix(path: server.path)) }
        XCTAssertEqual(state, TaildropState(availability: .disconnected))
        XCTAssertEqual(server.requests.map(\.path), ["/localapi/v0/status?peers=false"])
    }

    func testResponseHeaderParsing() throws {
        XCTAssertEqual(try TaildropClient.parseHeader("HTTP/1.1 200 OK\r\nContent-Length: 12\r\nX: y").length, 12)
        XCTAssertEqual(try TaildropClient.parseHeader("HTTP/1.0 403 Forbidden").status, 403)
        XCTAssertThrowsError(try TaildropClient.parseHeader("SSH-2.0-nope"))
        XCTAssertEqual(TaildropClient.message(Data("  denied\u{7}\nsecond".utf8)), "denied")
    }

    // MARK: Drop screen targets

    private let pdf = URL(fileURLWithPath: "/tmp/trip-notes.pdf", isDirectory: false)
    private let folder = URL(fileURLWithPath: "/tmp/Photos", isDirectory: true)

    func testDropTargetsAreOnePerDeviceWithOfflineDisabled() {
        var sent: [(String, [URL])] = []
        let targets = TaildropModule.dropTargets(state: .demo, sending: false, files: [pdf]) { sent.append(($0.id, $1)) }
        XCTAssertEqual(targets.map(\.id), TaildropState.demo.targets.map(\.id), "One target per device, id = its stable ID")
        XCTAssertEqual(targets.map(\.title), ["ipad-air", "pixel-8", "work-laptop", "home-nas"])
        XCTAssertEqual(targets.map(\.subtitle), ["iOS", "Android", "Windows", "Offline"])
        XCTAssertEqual(targets.map(\.enabled), [true, true, true, false])
        XCTAssertEqual(targets[1].glyph, "smartphone")
        targets[1].drop([pdf])
        XCTAssertEqual(sent.map(\.0), ["demo-pixel"])
        XCTAssertEqual(sent.first?.1, [pdf])
    }

    func testDropTargetsAreBusyWhileSendingAndRefuseOnlyFolders() {
        let busy = TaildropModule.dropTargets(state: .demo, sending: true, files: [pdf]) { _, _ in }
        XCTAssertTrue(busy.allSatisfy { !$0.enabled && $0.subtitle == "Busy sending" }, "A running send disables every device")
        let folders = TaildropModule.dropTargets(state: .demo, sending: false, files: [folder]) { _, _ in }
        XCTAssertTrue(folders.allSatisfy { !$0.enabled && $0.subtitle == "Folders can't be sent" })
        let mixed = TaildropModule.dropTargets(state: .demo, sending: false, files: [folder, pdf]) { _, _ in }
        XCTAssertEqual(mixed.map(\.enabled), [true, true, true, false], "A folder among files is skipped at send time, not refused")
    }

    func testDropTargetIsOneDisabledStateWhenTailscaleIsNotReady() {
        let cases: [(TaildropAvailability, String)] = [
            (.notRunning, "Tailscale is not running"), (.notInstalled, "Tailscale is not installed"),
            (.disconnected, "Tailscale is disconnected"), (.needsLogin, "Sign in to Tailscale"),
            (.ready, "No devices can receive files")
        ]
        for (availability, title) in cases {
            let targets = TaildropModule.dropTargets(state: TaildropState(availability: availability), sending: false, files: [pdf]) { _, _ in
                XCTFail("A state target never sends")
            }
            XCTAssertEqual(targets.count, 1)
            XCTAssertEqual(targets.first?.title, title)
            XCTAssertEqual(targets.first?.enabled, false)
        }
    }

    // MARK: Live (opt-in)

    /// `QNOTCH_TAILDROP_LIVE=1`: reads this Mac's Tailscale once (status, targets, inbox; nothing is
    /// sent or saved) and prints only the availability and counts, never names.
    func testLiveReadOnlyProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QNOTCH_TAILDROP_LIVE"] == "1", "live check is opt-in")
        let discovered = TaildropDiscovery.discover()
        let transport: String
        switch discovered {
        case .endpoint(.tcp): transport = "loopback TCP + same-user key"
        case .endpoint(.unix): transport = "unix socket"
        default: transport = "none"
        }
        let state = TaildropModule.probe(previous: TaildropState()) { discovered }
        print("taildrop-live: transport=\(transport) availability=\(state.availability) targets=\(state.targets.count) online=\(state.onlineTargets.count) offline=\(state.targets.count - state.onlineTargets.count) waiting=\(state.waiting.count) error=\(state.message == nil ? "none" : "yes")")
    }

    // MARK: Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qnotch-taildrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// A one-thread HTTP server on a Unix socket that records requests and answers from `respond`.
private final class FakeLocalAPI {
    struct Request { var method = "", path = "", headers: [String: String] = [:], body = Data() }

    let path = "/tmp/qnt-\(UUID().uuidString.prefix(8)).sock"
    private let fd: Int32
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var stopped = false
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }

    init(respond: @escaping (Request) -> (Int, String)) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { throw TaildropError.io("bind failed") }
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                guard let self else { close(client); return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let request = Self.read(client)
                self.lock.lock(); self.recorded.append(request); self.lock.unlock()
                let (status, body) = respond(request)
                let answer = "HTTP/1.0 \(status) X\r\nContent-Type: text/plain\r\n\r\n\(body)"
                _ = answer.utf8CString.withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count - 1, 0) }
                close(client)
            }
        }
    }

    func stop() {
        lock.lock(); let already = stopped; stopped = true; lock.unlock()
        guard !already else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    private static func read(_ client: Int32) -> Request {
        var buffer = Data()
        var request = Request()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var expected: Int?
        var headerEnd: Int?
        while true {
            if let end = headerEnd, let expected, buffer.count - end >= expected { break }
            if headerEnd != nil, expected == nil { break }
            let count = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            if headerEnd == nil, let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range.upperBound
                let lines = String(decoding: buffer[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                request.method = String(first[0])
                request.path = String(first[1])
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    request.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                expected = request.headers["content-length"].flatMap(Int.init)
            }
        }
        if let end = headerEnd { request.body = Data(buffer[end...]) }
        return request
    }
}
