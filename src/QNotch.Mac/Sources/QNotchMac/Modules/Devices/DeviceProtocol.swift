import Foundation
import CryptoKit
import Network

enum DeviceError: Error { case invalid, declined, unavailable, disconnected }

struct DevicePeer: Codable, Equatable {
    let id: String
    let name: String
    var host: String
    let port: Int
    var receive: Bool = true
    var syncNotes = false
    var syncClipboard = false
    init(id: String, name: String, host: String, port: Int, receive: Bool = true, syncNotes: Bool = false, syncClipboard: Bool = false) {
        self.id = id; self.name = name; self.host = host; self.port = port; self.receive = receive
        self.syncNotes = syncNotes; self.syncClipboard = syncClipboard
    }
    private enum CodingKeys: String, CodingKey { case id, name, host, port, receive, syncNotes, syncClipboard }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host); port = try values.decode(Int.self, forKey: .port)
        receive = try values.decodeIfPresent(Bool.self, forKey: .receive) ?? true
        syncNotes = try values.decodeIfPresent(Bool.self, forKey: .syncNotes) ?? false
        syncClipboard = try values.decodeIfPresent(Bool.self, forKey: .syncClipboard) ?? false
    }
}

struct DeviceInvitation: Codable {
    let v: Int
    let id: String
    let name: String
    let host: String
    let port: Int
    let secret: String
    let expires: Int64
    var code: String { "qnotch-device:" + ((try? JSONEncoder().encode(self)) ?? Data()).base64EncodedString() }
    static func parse(_ code: String) throws -> Self {
        guard code.count <= 4096, code.hasPrefix("qnotch-device:"), let bytes = Data(base64Encoded: String(code.dropFirst(14))) else { throw DeviceError.invalid }
        let invite = try JSONDecoder().decode(Self.self, from: bytes)
        guard invite.v == 1, DeviceWire.validID(invite.id), !invite.name.isEmpty, invite.name.count <= 80,
              DeviceWire.localAddress(invite.host), (1...65535).contains(invite.port), Data(base64Encoded: invite.secret)?.count == 32,
              invite.expires > Int64(Date().timeIntervalSince1970) else { throw DeviceError.invalid }
        return invite
    }
}

struct DeviceMessage: Codable {
    let op: String
    var id: String? = nil
    var name: String? = nil
    var port: Int? = nil
    var key: String? = nil
    var text: String? = nil
    var size: Int64? = nil
}
struct DeviceReply: Codable {
    let ok: Bool
    var error: String? = nil
    var id: String? = nil
    var name: String? = nil
    var size: Int64? = nil
}
struct DeviceHello: Codable { let v: Int; let id: String; let pair: Bool; let nonce: String }

enum DeviceWire {
    static let chunk = 65536
    static let maxFile: Int64 = 2147483648
    static let maxSync = 8 * 1024 * 1024
    static func validID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    static func randomKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    static func localAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { UInt8($0) }
        guard bytes.count == 4, zip(parts, bytes).allSatisfy({ String($0.1) == $0.0 }) else { return false }
        return bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 169 && bytes[1] == 254) ||
            (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }
    static func validateName(_ name: String) throws {
        let stem = name.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init)?.uppercased() ?? ""
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        guard !name.isEmpty, name.utf8.count <= 180, name != ".", name != "..", !name.hasSuffix("."), !name.hasSuffix(" "),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "<>:\"/\\|?*".unicodeScalars.contains($0) }),
              !reserved.contains(stem) else { throw DeviceError.invalid }
    }
    static func connectionKey(secret: Data, challenge: Data, hello: Data) -> Data {
        let input = challenge + Data(SHA256.hash(data: hello)) + Data("qnotch-devices-v1".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: secret)))
    }
    static func aad(challenge: Data, direction: UInt8, sequence: UInt64) -> Data {
        var value = sequence.bigEndian
        return challenge + Data([direction]) + withUnsafeBytes(of: &value) { Data($0) }
    }
    static func seal(key: Data, plain: Data, aad: Data, nonce: Data? = nil) throws -> Data {
        guard plain.count <= chunk else { throw DeviceError.invalid }
        let n = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        guard let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: n, authenticating: aad).combined else { throw DeviceError.invalid }
        return box
    }
    static func open(key: Data, box: Data, aad: Data) throws -> Data {
        guard (28...(chunk + 28)).contains(box.count) else { throw DeviceError.invalid }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: SymmetricKey(data: key), authenticating: aad)
    }
}

/// Exactly one reader and writer per connection. Network.framework owns socket I/O on a utility queue.
final class DeviceSocket {
    let connection: NWConnection
    private let deadline: DispatchWorkItem
    init(_ connection: NWConnection) {
        self.connection = connection
        deadline = DispatchWorkItem { connection.cancel() }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: deadline)
    }
    func close() { deadline.cancel(); connection.cancel() }
    func write(_ bytes: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func read(_ count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            try Task.checkCancellation()
            let remaining = count - bytes.count
            let piece: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: DeviceError.disconnected) }
                }
            }
            bytes.append(piece)
        }
        return bytes
    }
    func writePacket(_ bytes: Data) async throws {
        var size = UInt32(bytes.count).bigEndian
        try await write(withUnsafeBytes(of: &size) { Data($0) } + bytes)
    }
    func readPacket(max: Int) async throws -> Data {
        let header = try await read(4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= max else { throw DeviceError.invalid }
        return try await read(Int(size))
    }
}

final class DeviceChannel {
    let socket: DeviceSocket
    let key: Data
    let challenge: Data
    let client: Bool
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    init(socket: DeviceSocket, key: Data, challenge: Data, client: Bool) {
        self.socket = socket; self.key = key; self.challenge = challenge; self.client = client
    }
    func send(_ plain: Data) async throws {
        let aad = DeviceWire.aad(challenge: challenge, direction: client ? 0 : 1, sequence: sent)
        sent += 1
        try await socket.writePacket(DeviceWire.seal(key: key, plain: plain, aad: aad))
    }
    func read() async throws -> Data {
        let aad = DeviceWire.aad(challenge: challenge, direction: client ? 1 : 0, sequence: received)
        received += 1
        return try DeviceWire.open(key: key, box: await socket.readPacket(max: DeviceWire.chunk + 28), aad: aad)
    }
    func send<T: Encodable>(_ value: T) async throws { try await send(JSONEncoder().encode(value)) }
    func reply() async throws -> DeviceReply { try JSONDecoder().decode(DeviceReply.self, from: await read()) }
    func checkReply() async throws { guard try await reply().ok else { throw DeviceError.declined } }
    func sendBytes(_ data: Data) async throws {
        var offset = 0
        while offset < data.count { let end = min(data.count, offset + DeviceWire.chunk); try await send(data.subdata(in: offset..<end)); offset = end }
    }
    func readBytes(_ count: Int64) async throws -> Data {
        guard count > 0, count <= DeviceWire.maxSync else { throw DeviceError.invalid }
        var data = Data()
        while data.count < count {
            let chunk = try await read()
            guard !chunk.isEmpty, chunk.count <= count - Int64(data.count) else { throw DeviceError.invalid }
            data.append(chunk)
        }
        return data
    }
}

/// File work is serialized off the main thread. Only bounded chunks cross the actor boundary.
actor DeviceDisk {
    func prepare(_ path: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: path.path), FileManager.default.createFile(atPath: path.path, contents: nil) else { throw DeviceError.unavailable }
        return try FileHandle(forWritingTo: path)
    }
    func append(_ data: Data, to file: FileHandle) throws { try file.write(contentsOf: data) }
    func finish(_ file: FileHandle, part: URL, target: URL) throws {
        try file.synchronize(); try file.close(); try FileManager.default.moveItem(at: part, to: target)
    }
    func discard(_ file: FileHandle?, part: URL) { try? file?.close(); try? FileManager.default.removeItem(at: part) }
    func saveText(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
    func open(_ url: URL) throws -> (FileHandle, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        do { let size = try handle.seekToEnd(); try handle.seek(toOffset: 0); return (handle, Int64(size)) }
        catch { try? handle.close(); throw error }
    }
    func read(_ file: FileHandle, count: Int) throws -> Data { try file.read(upToCount: count) ?? Data() }
    func close(_ file: FileHandle) { try? file.close() }
}
