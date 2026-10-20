import XCTest
import AppKit
import QNotchMacCore
@testable import QNotchMac

final class DebugChannelTests: XCTestCase {
    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: Protocol

    func testParsesRequests() throws {
        let request = try DebugProtocol.parse(Data(#"{"id":1,"cmd":"select-tab","args":{"id":"timer"}}"#.utf8)).get()
        XCTAssertEqual(request.id as? Int, 1)
        XCTAssertEqual(request.command, "select-tab")
        XCTAssertEqual(request.args["id"] as? String, "timer")
        let bare = try DebugProtocol.parse(Data(#"{"cmd":"ping","args":null}"#.utf8)).get()
        XCTAssertNil(bare.id)
        XCTAssertTrue(bare.args.isEmpty)
        XCTAssertEqual(try DebugProtocol.parse(Data(#"{"id":"a","cmd":"state"}"#.utf8)).get().id as? String, "a")
    }

    func testRejectsMalformedRequests() {
        for (line, message, id) in [("nope", "not a JSON object", nil), ("[1]", "not a JSON object", nil), (#"{"id":7}"#, "no cmd", 7),
                                    (#"{"id":7,"cmd":"ping","args":[1]}"#, "args must be an object", 7)] as [(String, String, Int?)] {
            guard case .failure(let failure) = DebugProtocol.parse(Data(line.utf8)) else { return XCTFail(line) }
            XCTAssertTrue(failure.message.contains(message), line)
            XCTAssertEqual(failure.id as? Int, id, line)
        }
        let large = Data(("{\"cmd\":\"type\",\"args\":{\"text\":\"" + String(repeating: "a", count: DebugProtocol.maxRequest) + "\"}}").utf8)
        guard case .failure(let failure) = DebugProtocol.parse(large) else { return XCTFail("64 KB") }
        XCTAssertEqual(failure.message, DebugProtocol.tooLarge)
    }

    func testEncodesResponsesWithTheIdEchoed() {
        XCTAssertEqual(String(decoding: DebugProtocol.success(id: 1, result: [:]), as: UTF8.self), "{\"id\":1,\"ok\":true,\"result\":{}}\n")
        XCTAssertEqual(String(decoding: DebugProtocol.failure(id: 2, error: "no visible control with id nope"), as: UTF8.self),
                       "{\"id\":2,\"ok\":false,\"error\":\"no visible control with id nope\"}\n")
        XCTAssertEqual(String(decoding: DebugProtocol.success(id: nil, result: ["path": "/tmp/x.png"]), as: UTF8.self),
                       "{\"ok\":true,\"result\":{\"path\":\"/tmp/x.png\"}}\n")
        XCTAssertEqual(String(decoding: DebugProtocol.failure(id: NSNull(), error: "a \"b\"\nc"), as: UTF8.self),
                       "{\"id\":null,\"ok\":false,\"error\":\"a \\\"b\\\"\\nc\"}\n")
        let echoed = json(DebugProtocol.success(id: ["x": [1, "y"]], result: ["text": "é\n"]))
        XCTAssertEqual((echoed["id"] as? [String: Any])?["x"] as? [AnyHashable], [1, "y"])
        XCTAssertEqual((echoed["result"] as? [String: Any])?["text"] as? String, "é\n")
    }

    func testSplitsLinesAndRefusesOversizedOnes() {
        var buffer = DebugLineBuffer(limit: 16)
        XCTAssertEqual(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)), [.line(Data("{\"a\":1}".utf8))])
        XCTAssertEqual(buffer.append(Data(":2}\n\n  \n".utf8)), [.line(Data("{\"b\":2}".utf8))])
        // Too long without a newline: refused once, the rest of it dropped, the next line parsed.
        XCTAssertEqual(buffer.append(Data(String(repeating: "x", count: 20).utf8)), [.tooLarge])
        XCTAssertEqual(buffer.append(Data(String(repeating: "x", count: 20).utf8)), [])
        XCTAssertEqual(buffer.append(Data("xx\n{}\n".utf8)), [.line(Data("{}".utf8))])
        // Too long within one chunk.
        XCTAssertEqual(buffer.append(Data((String(repeating: "y", count: 17) + "\n{}\n").utf8)), [.tooLarge, .line(Data("{}".utf8))])
        XCTAssertEqual(DebugLineBuffer().limit, 64 * 1024)
    }

    func testConvertsFramesToTopLeftOrigin() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // A panel hanging from the top edge of the primary display.
        XCTAssertEqual(DebugProtocol.topLeft(CGRect(x: 640, y: 552, width: 232, height: 430), primary: primary), CGRect(x: 640, y: 0, width: 232, height: 430))
        // A display above and to the left of the primary one (AppKit: positive y above).
        XCTAssertEqual(DebugProtocol.topLeft(CGRect(x: -1920, y: 982, width: 1920, height: 1080), primary: primary), CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
        XCTAssertEqual(DebugProtocol.topLeft(CGRect(x: 10, y: 10, width: 100, height: 50), primary: primary).minY, 922)
        let frame = DebugProtocol.frame(CGRect(x: 640.004, y: 0, width: 760.5, height: 430))
        XCTAssertEqual(frame["x"] as? Double, 640)
        XCTAssertEqual(frame["width"] as? Double, 760.5)
    }

    func testKeysAndModifiers() {
        XCTAssertEqual(DebugKey.stroke("Escape"), DebugKey.Stroke(keyCode: 0x35, characters: "\u{1B}"))
        XCTAssertEqual(DebugKey.stroke("return")?.keyCode, 0x24)
        XCTAssertEqual(DebugKey.stroke("Up")?.characters.unicodeScalars.first?.value, 0xF700)
        XCTAssertEqual(DebugKey.stroke("Backspace")?.keyCode, 0x33)
        XCTAssertEqual(DebugKey.stroke("Delete")?.keyCode, 0x75)
        XCTAssertEqual(DebugKey.stroke("n"), DebugKey.Stroke(keyCode: 0x2D, characters: "n"))
        XCTAssertEqual(DebugKey.stroke("/")?.keyCode, 0x2C)
        XCTAssertEqual(DebugKey.stroke(" ")?.keyCode, 0x31)
        XCTAssertEqual(DebugKey.stroke("é"), DebugKey.Stroke(keyCode: 0, characters: "é"))
        XCTAssertNil(DebugKey.stroke("Home"))
        XCTAssertNil(DebugKey.stroke(""))
        XCTAssertEqual(DebugKey.modifiers("ctrl,alt+shift cmd"), ["ctrl", "alt", "shift", "cmd"])
        XCTAssertEqual(DebugKey.modifiers(["option", "command"]), ["alt", "cmd"])
        XCTAssertEqual(DebugKey.modifiers(nil), [])
        XCTAssertNil(DebugKey.modifiers("hyper"))
        XCTAssertNil(DebugKey.modifiers(3))
    }

    // MARK: Command line

    func testMapsArgumentsToARequest() throws {
        let invocation = try DebugCLI.parse(["type", "--text", "42", "--id", "search-field", "--data-dir", "/tmp/q"])
        XCTAssertEqual(invocation.command, "type")
        XCTAssertEqual(invocation.dataDirectory, "/tmp/q")
        XCTAssertEqual(invocation.args["text"] as? String, "42")
        XCTAssertNil(invocation.args["data-dir"])
        let request = json(DebugCLI.request(invocation))
        XCTAssertEqual(request["cmd"] as? String, "type")
        XCTAssertEqual(request["id"] as? Int, 1)
        XCTAssertEqual((request["args"] as? [String: Any])?["id"] as? String, "search-field")
        XCTAssertTrue(DebugCLI.request(invocation).last == 0x0A)

        let flags = try DebugCLI.parse(["settings", "--close", "--count", "3", "--scale", "1.5", "--label", "false", "--note", "x y"])
        XCTAssertEqual(flags.args["close"] as? Bool, true)
        XCTAssertEqual(flags.args["count"] as? Int, 3)
        XCTAssertEqual(flags.args["scale"] as? Double, 1.5)
        XCTAssertEqual(flags.args["label"] as? Bool, false)
        XCTAssertEqual(flags.args["note"] as? String, "x y")
        XCTAssertEqual(DebugCLI.value("1.2.3", key: "v") as? String, "1.2.3")
        XCTAssertEqual(DebugCLI.value("true", key: "text") as? String, "true")
        XCTAssertTrue(try DebugCLI.parse(["state"]).args.isEmpty)
    }

    func testRejectsBadUsage() {
        for args in [["--text", "x"], ["frobnicate"], ["press", "id"], ["ping", "--data-dir"], ["ping", "--"]] {
            XCTAssertThrowsError(try DebugCLI.parse(args), args.joined(separator: " ")) { XCTAssertTrue($0 is DebugCLI.UsageError) }
        }
    }

    func testReplyOutcomes() {
        let ok = DebugCLI.outcome(Data("{\"id\":1,\"ok\":true,\"result\":{\"text\":\"a\"}}\n".utf8))
        XCTAssertEqual(ok.code, 0)
        XCTAssertEqual(ok.stdout, "{\"text\":\"a\"}")
        let failed = DebugCLI.outcome(Data("{\"id\":1,\"ok\":false,\"error\":\"no visible control with id nope\"}\n".utf8))
        XCTAssertEqual(failed.code, 1)
        XCTAssertEqual(failed.stderr, "{\"error\":\"no visible control with id nope\"}")
        XCTAssertEqual(DebugCLI.outcome(Data("garbage".utf8)).code, 1)
    }

    func testClientExitCodes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(DebugClient.run([]), 4)
        XCTAssertEqual(DebugClient.run(["--help"]), 0)
        XCTAssertEqual(DebugClient.run(["frobnicate"]), 4)
        XCTAssertEqual(DebugClient.run(["ping", "--data-dir", directory.path]), 3)
        XCTAssertEqual(DebugClient.run(["ping"], environment: ["QNOTCH_MAC_DATA_DIR": directory.path]), 3)
    }

    // MARK: Arguments and settling

    func testArguments() throws {
        let args = Arguments(values: ["id": "timer", "n": 3, "close": true, "one": 1, "word": "false", "bad": [1]])
        XCTAssertEqual(try args.string("id"), "timer")
        XCTAssertEqual(try args.string("n"), "3")
        XCTAssertNil(try args.string("missing"))
        XCTAssertThrowsError(try args.string("close"))
        XCTAssertThrowsError(try args.required("missing", for: "press")) { XCTAssertEqual(($0 as? DebugCommands.Failure)?.message, "press needs missing") }
        XCTAssertTrue(try args.bool("close"))
        XCTAssertTrue(try args.bool("one"))
        XCTAssertFalse(try args.bool("word"))
        XCTAssertFalse(try args.bool("missing"))
        XCTAssertThrowsError(try args.bool("bad"))
    }

    /// Windows' command line sends every value as a string.
    func testStringArgumentValues() throws {
        let args = Arguments(values: ["t": "true", "f": "false", "T": "True", "one": "1", "zero": "0", "two": 2, "yes": "yes",
                                      "n": "42", "d": "-1.5", "i": 7, "flag": true, "nan": "NaN", "word": "many"])
        XCTAssertTrue(try args.bool("t"))
        XCTAssertFalse(try args.bool("f"))
        XCTAssertTrue(try args.bool("T"))
        XCTAssertTrue(try args.bool("one"))
        XCTAssertFalse(try args.bool("zero"))
        XCTAssertThrowsError(try args.bool("two"))
        XCTAssertThrowsError(try args.bool("yes")) { XCTAssertEqual(($0 as? DebugCommands.Failure)?.message, "yes must be true or false") }
        XCTAssertEqual(try args.number("n"), 42)
        XCTAssertEqual(try args.number("d"), -1.5)
        XCTAssertEqual(try args.number("i"), 7)
        XCTAssertNil(try args.number("missing"))
        XCTAssertThrowsError(try args.number("flag"))
        XCTAssertThrowsError(try args.number("nan"))
        XCTAssertThrowsError(try args.number("word")) { XCTAssertEqual(($0 as? DebugCommands.Failure)?.message, "word must be a number") }
        // A request as Windows' CLI sends it.
        let request = try DebugProtocol.parse(Data(#"{"id":"1","cmd":"settings","args":{"close":"true"}}"#.utf8)).get()
        XCTAssertTrue(try Arguments(values: request.args).bool("close"))
    }

    func testAnimationLengths() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.duration = 0.25
        XCTAssertEqual(DebugSettle.length(of: fade), 0.25)
        fade.repeatCount = 2
        fade.autoreverses = true
        XCTAssertEqual(DebugSettle.length(of: fade), 1)
        fade.repeatCount = .infinity
        XCTAssertNil(DebugSettle.length(of: fade))
        let layer = CALayer()
        let child = CALayer()
        layer.addSublayer(child)
        XCTAssertFalse(DebugSettle.animating(layer, since: CACurrentMediaTime()))
        let move = CABasicAnimation(keyPath: "position")
        move.duration = 5
        child.add(move, forKey: "move")
        XCTAssertTrue(DebugSettle.animating(layer, since: CACurrentMediaTime()))
        XCTAssertFalse(DebugSettle.animating(layer, since: CACurrentMediaTime() - 10))
    }

    // MARK: Socket

    private func temporaryDirectory() throws -> URL {
        // Short: a socket path must fit in 104 bytes.
        let url = URL(fileURLWithPath: "/tmp/qn-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `payload` in one go and reads `count` reply lines.
    private func exchange(_ payload: Data, path: String, lines count: Int) -> [String] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
        }
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0 else { return [] }
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while reply.filter({ $0 == 0x0A }).count < count {
            let read = Darwin.read(fd, &chunk, chunk.count)
            guard read > 0 else { break }
            reply.append(contentsOf: chunk[0..<read])
        }
        return String(decoding: reply, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func testSocketRoundTripAnswersInOrder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(DebugChannel.fileName).path
        var handled: [String] = []
        let channel = try DebugChannel(path: path) { request, reply in
            XCTAssertTrue(Thread.isMainThread)
            handled.append(request.command)
            // The first answer is late: the second request must still wait for it.
            let delay = request.command == "slow" ? 0.2 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                reply(request.command == "fail" ? DebugProtocol.failure(id: request.id, error: "failed") :
                        DebugProtocol.success(id: request.id, result: ["cmd": request.command]), nil)
            }
        }
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)

        let done = expectation(description: "replies")
        var lines: [String] = []
        var cli: Result<Data, DebugClient.Failure>?
        DispatchQueue.global().async {
            let oversized = "{\"cmd\":\"type\",\"args\":{\"text\":\"" + String(repeating: "a", count: DebugProtocol.maxRequest) + "\"}}\n"
            let payload = "{\"id\":1,\"cmd\":\"slow\"}\n{\"id\":2,\"cmd\":\"fast\"}\nnot json\n" + oversized + "{\"cmd\":\"fail\"}\n"
            lines = self.exchange(Data(payload.utf8), path: path, lines: 5)
            cli = DebugClient.send(Data("{\"id\":\"x\",\"cmd\":\"ping\"}\n".utf8), to: path, timeout: 5)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(lines, ["{\"id\":1,\"ok\":true,\"result\":{\"cmd\":\"slow\"}}",
                               "{\"id\":2,\"ok\":true,\"result\":{\"cmd\":\"fast\"}}",
                               "{\"ok\":false,\"error\":\"The request is not a JSON object.\"}",
                               "{\"ok\":false,\"error\":\"The request is larger than 64 KB.\"}",
                               "{\"ok\":false,\"error\":\"failed\"}"])
        XCTAssertEqual(handled, ["slow", "fast", "fail", "ping"])
        guard case .success(let reply)? = cli else { return XCTFail("the client got no reply") }
        XCTAssertEqual(DebugCLI.outcome(reply).stdout, "{\"cmd\":\"ping\"}")

        // A second channel on a live socket fails; closing removes the socket.
        XCTAssertThrowsError(try DebugChannel(path: path) { _, _ in })
        channel.close()
        XCTAssertNotEqual(lstat(path, &info), 0)
    }

    func testStaleSocketsAreReplacedButOtherFilesAreNot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(DebugChannel.fileName).path
        // A socket left by a run that was killed: bound, never listening.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
        }
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        close(fd)
        XCTAssertFalse(DebugClient.isListening(path))
        let channel = try DebugChannel(path: path) { _, _ in }
        XCTAssertTrue(DebugClient.isListening(path))
        channel.close()

        FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))
        XCTAssertThrowsError(try DebugChannel(path: path) { _, _ in })
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data("keep".utf8))
    }
}
