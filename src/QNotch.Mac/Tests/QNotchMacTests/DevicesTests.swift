import Foundation
import XCTest
@testable import QNotchMac

final class DevicesTests: XCTestCase {
    private var repository: URL {
        var path = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { path.deleteLastPathComponent() }
        return path
    }
    private func fixture() throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(contentsOf: repository.appendingPathComponent("tests/fixtures/devices/wire-v1.json")))
    }
    private func bytes(_ value: String) -> Data {
        var data = Data(), index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2); data.append(UInt8(value[index..<next], radix: 16)!); index = next
        }
        return data
    }
    func testIndependentWireVectorAndTampering() throws {
        let vector = try fixture()
        func data(_ key: String) -> Data { bytes(vector[key]!) }
        let key = DeviceWire.connectionKey(secret: data("secret"), challenge: data("challenge"), hello: data("hello"))
        XCTAssertEqual(key, data("key"))
        let aad = DeviceWire.aad(challenge: data("challenge"), direction: 0, sequence: 0)
        XCTAssertEqual(aad, data("aad"))
        let box = try DeviceWire.seal(key: key, plain: data("plain"), aad: aad, nonce: data("nonce"))
        XCTAssertEqual(box, data("box"))
        XCTAssertEqual(try DeviceWire.open(key: key, box: box, aad: aad), data("plain"))
        XCTAssertThrowsError(try DeviceWire.open(key: key, box: box, aad: DeviceWire.aad(challenge: data("challenge"), direction: 1, sequence: 0)))
        XCTAssertThrowsError(try DeviceWire.open(key: key, box: box, aad: DeviceWire.aad(challenge: data("challenge"), direction: 0, sequence: 1)))
        var damaged = box; damaged[damaged.count - 1] ^= 1
        XCTAssertThrowsError(try DeviceWire.open(key: key, box: damaged, aad: aad))
    }
    func testValidationAndInvitation() throws {
        for name in ["", "..", "../escape", "a\\b", "CON.txt", "LPT9", "a:", "x.", "x ", "a\0b"] { XCTAssertThrowsError(try DeviceWire.validateName(name)) }
        XCTAssertNoThrow(try DeviceWire.validateName("árvíztűrő.txt"))
        XCTAssertTrue(DeviceWire.localAddress("192.168.1.20")); XCTAssertFalse(DeviceWire.localAddress("8.8.8.8"))
        let invitation = DeviceInvitation(v: 1, id: UUID().uuidString.lowercased(), name: "Mac", host: "127.0.0.1", port: 45874,
                                          secret: DeviceWire.randomKey().base64EncodedString(), expires: Int64(Date().timeIntervalSince1970) + 300)
        XCTAssertEqual(try DeviceInvitation.parse(invitation.code).id, invitation.id)
    }
    @MainActor func testNativePairTextFilesPermissionsAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = DeviceNode(id: UUID().uuidString.lowercased(), name: "Mac A", inbox: root.appendingPathComponent("a"))
        let b = DeviceNode(id: UUID().uuidString.lowercased(), name: "Mac B", inbox: root.appendingPathComponent("b"))
        defer { a.stop(); b.stop(); try? FileManager.default.removeItem(at: root) }
        a.approve = { _ in true }; a.persist = { _, _ in true }; b.persist = { _, _ in true }
        try await a.start(port: 0); try await b.start(port: 0)
        let invite = try a.invite(host: "127.0.0.1").code
        try await b.pair(invite)
        XCTAssertEqual(a.devices.count, 1); XCTAssertEqual(b.devices.count, 1)
        try await a.send(b.id, text: "Mac to Mac 👋"); try await b.send(a.id, text: "Reverse")
        let payload = root.appendingPathComponent("payload.bin"), data = Data(repeating: 123, count: DeviceWire.chunk * 3 + 17)
        try data.write(to: payload)
        try await a.send(b.id, file: payload); try await a.send(b.id, file: payload)
        let received = try FileManager.default.contentsOfDirectory(at: b.inbox, includingPropertiesForKeys: nil)
        let files = received.filter { $0.lastPathComponent.hasSuffix("payload.bin") }
        XCTAssertEqual(files.count, 2); for file in files { XCTAssertEqual(try Data(contentsOf: file), data) }
        try Data().write(to: payload); try await b.send(a.id, file: payload)
        a.setReceive(b.id, false)
        do { try await b.send(a.id, text: "blocked"); XCTFail("Receiving should be off") } catch { }
        a.setReceive(b.id, true); a.remove(b.id)
        do { try await b.send(a.id, text: "revoked"); XCTFail("Peer should be revoked") } catch { }
    }
    @MainActor func testWindowsTransportInteroperability() async throws {
        guard let executable = ProcessInfo.processInfo.environment["QNOTCH_DEVICE_TEST_DLL"] else {
            throw XCTSkip("Set QNOTCH_DEVICE_TEST_DLL to the built .NET device test harness for native/.NET interoperability checks.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let native = DeviceNode(id: UUID().uuidString.lowercased(), name: "Mac", inbox: root.appendingPathComponent("mac"))
        native.persist = { _, _ in true }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["dotnet", executable, "--serve", root.appendingPathComponent("dotnet").path]
        process.standardOutput = pipe; process.standardError = FileHandle.standardError
        try process.run()
        defer { native.stop(); if process.isRunning { process.terminate(); process.waitUntilExit() }; try? FileManager.default.removeItem(at: root) }
        let invitation: String = try await Task { () throws -> String in
            var line = Data()
            while line.count < 4096 {
                guard let next = try pipe.fileHandleForReading.read(upToCount: 1), !next.isEmpty else { throw DeviceError.disconnected }
                if next == Data([10]) { return String(decoding: line, as: UTF8.self) }; line.append(next)
            }
            throw DeviceError.invalid
        }.value
        try await native.start(port: 0); try await native.pair(invitation)
        let echoed = expectation(description: "Windows transport returns text and file to native Mac")
        echoed.expectedFulfillmentCount = 2
        native.received = { _, _, _ in echoed.fulfill() }
        try await native.send(native.devices[0].id, text: "Mac → Windows → Mac 👋")
        let file = root.appendingPathComponent("cross-platform.bin"), data = Data(repeating: 42, count: DeviceWire.chunk * 2 + 23)
        try data.write(to: file); try await native.send(native.devices[0].id, file: file)
        await fulfillment(of: [echoed], timeout: 20)
        let paths = try FileManager.default.contentsOfDirectory(at: native.inbox, includingPropertiesForKeys: nil)
        XCTAssertTrue(try paths.contains { try Data(contentsOf: $0) == data })
        XCTAssertTrue(paths.contains { (try? String(contentsOf: $0, encoding: .utf8)) == "Mac → Windows → Mac 👋" })
    }
}
