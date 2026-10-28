import Foundation
import Network

/// The module calls synchronous state methods on the main thread; async operations explicitly
/// return to the main actor between socket awaits. Disk work lives in DeviceDisk.
final class DeviceNode {
    let id: String
    let name: String
    let inbox: URL
    private(set) var port = 0
    private var listener: NWListener?
    private var invitation: DeviceInvitation?
    private var pairing = false
    private var peers: [String: (DevicePeer, Data)] = [:]
    private var sockets: [UUID: DeviceSocket] = [:]
    private var generation = UUID()
    private let disk = DeviceDisk()
    var approve: @MainActor (DevicePeer) async -> Bool = { _ in false }
    var persist: @MainActor (DevicePeer, Data) async -> Bool = { _, _ in false }
    var changed: () -> Void = {}
    var received: (String, URL, Bool) -> Void = { _, _, _ in }
    var devices: [DevicePeer] { peers.values.map(\.0).sorted { $0.name < $1.name } }
    init(id: String, name: String, inbox: URL) { self.id = id; self.name = name; self.inbox = inbox }
    func restore(_ peer: DevicePeer, key: Data) { if key.count == 32 { peers[peer.id] = (peer, key) } }
    func remove(_ id: String) { peers[id] = nil; for socket in sockets.values { socket.close() }; changed() }
    func setReceive(_ id: String, _ receive: Bool) {
        peers[id]?.0.receive = receive
        if !receive { for socket in sockets.values { socket.close() } }
    }

    @MainActor func start(port requested: Int = 45874) async throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: requested) ?? 0) else { throw DeviceError.invalid }
        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener
        let current = generation
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.sockets.count < 4,
                      case let .hostPort(host, _) = connection.endpoint, DeviceWire.localAddress(String(describing: host)) else { connection.cancel(); return }
                let socket = DeviceSocket(connection), token = UUID()
                self.sockets[token] = socket
                defer { socket.close(); self.sockets[token] = nil }
                try? await self.serve(socket, host: String(describing: host), generation: current)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // All listener callbacks are serialized on main; consume this handler exactly once.
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    self?.port = Int(listener.port?.rawValue ?? 0)
                    continuation.resume()
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                case .cancelled: listener.stateUpdateHandler = nil; continuation.resume(throwing: DeviceError.unavailable)
                default: break
                }
            }
            listener.start(queue: .main)
        }
    }
    func invite(host: String) throws -> DeviceInvitation {
        guard port > 0, DeviceWire.localAddress(host) else { throw DeviceError.unavailable }
        let value = DeviceInvitation(v: 1, id: id, name: name, host: host, port: port,
                                     secret: DeviceWire.randomKey().base64EncodedString(), expires: Int64(Date().timeIntervalSince1970) + 300)
        invitation = value
        return value
    }
    @MainActor private func serve(_ socket: DeviceSocket, host: String, generation current: UUID) async throws {
        let bytes = try await socket.readPacket(max: 1024)
        let hello = try JSONDecoder().decode(DeviceHello.self, from: bytes)
        guard hello.v == 1, DeviceWire.validID(hello.id), hello.id != id, Data(base64Encoded: hello.nonce)?.count == 32 else { throw DeviceError.invalid }
        let secret: Data
        let invite = invitation
        if hello.pair {
            guard !pairing, let invite, invite.expires > Int64(Date().timeIntervalSince1970), let key = Data(base64Encoded: invite.secret) else { throw DeviceError.declined }
            secret = key; pairing = true
        } else {
            guard let peer = peers[hello.id] else { throw DeviceError.declined }
            secret = peer.1
        }
        defer { if hello.pair { pairing = false } }
        let challenge = DeviceWire.randomKey()
        try await socket.write(challenge)
        let channel = DeviceChannel(socket: socket, key: DeviceWire.connectionKey(secret: secret, challenge: challenge, hello: bytes), challenge: challenge, client: false)
        let request = try JSONDecoder().decode(DeviceMessage.self, from: await channel.read())
        if hello.pair {
            guard request.op == "pair", request.id == hello.id, let name = request.name, !name.isEmpty, name.count <= 80,
                  let port = request.port, (1...65535).contains(port), let encoded = request.key, let key = Data(base64Encoded: encoded), key.count == 32, peers[hello.id] == nil else { throw DeviceError.invalid }
            let peer = DevicePeer(id: hello.id, name: name, host: host, port: port)
            guard await approve(peer), current == generation, invitation?.secret == invite?.secret,
                  (invite?.expires ?? 0) > Int64(Date().timeIntervalSince1970), peers.count < 20, await persist(peer, key) else {
                try await channel.send(DeviceReply(ok: false, error: "Pairing declined, expired or could not be saved.")); return
            }
            peers[peer.id] = (peer, key); invitation = nil; changed()
            try await channel.send(DeviceReply(ok: true, id: id, name: self.name)); return
        }
        guard current == generation, let trusted = peers[hello.id], trusted.0.receive else { try await channel.send(DeviceReply(ok: false, error: "Receiving from this device is off.")); return }
        if request.op == "ping" { try await channel.send(DeviceReply(ok: true)); return }
        if request.op == "text", let text = request.text, text.utf16.count <= 16000 {
            let path = inbox.appendingPathComponent(UUID().uuidString.lowercased() + "-text.txt")
            try await disk.saveText(text, at: path)
            received(trusted.0.name, path, false); try await channel.send(DeviceReply(ok: true)); return
        }
        guard request.op == "file", let name = request.name, let length = request.size, (0...DeviceWire.maxFile).contains(length) else { throw DeviceError.invalid }
        try DeviceWire.validateName(name)
        let target = inbox.appendingPathComponent(UUID().uuidString.lowercased() + "-" + name)
        let part = target.appendingPathExtension("part")
        let file = try await disk.prepare(part)
        do {
            try await channel.send(DeviceReply(ok: true))
            var count: Int64 = 0
            while count < length {
                let data = try await channel.read()
                guard !data.isEmpty, data.count <= length - count, current == generation, peers[hello.id] != nil else { throw DeviceError.invalid }
                try await disk.append(data, to: file); count += Int64(data.count)
            }
            guard current == generation, peers[hello.id]?.0.receive == true else { throw DeviceError.declined }
            try await disk.finish(file, part: part, target: target)
            received(trusted.0.name, target, true); try await channel.send(DeviceReply(ok: true))
        } catch { await disk.discard(file, part: part); throw error }
    }
    @MainActor private func use(_ peer: DevicePeer, key: Data, pair: Bool, action: (DeviceChannel) async throws -> Void) async throws {
        guard port > 0, DeviceWire.localAddress(peer.host), (1...65535).contains(peer.port), let port = NWEndpoint.Port(rawValue: UInt16(peer.port)) else { throw DeviceError.unavailable }
        let socket = DeviceSocket(NWConnection(host: NWEndpoint.Host(peer.host), port: port, using: .tcp)), token = UUID()
        sockets[token] = socket
        defer { socket.close(); sockets[token] = nil }
        try await withTaskCancellationHandler {
            let bytes = try JSONEncoder().encode(DeviceHello(v: 1, id: id, pair: pair, nonce: DeviceWire.randomKey().base64EncodedString()))
            try await socket.writePacket(bytes)
            let challenge = try await socket.read(32)
            try await action(DeviceChannel(socket: socket, key: DeviceWire.connectionKey(secret: key, challenge: challenge, hello: bytes), challenge: challenge, client: true))
        } onCancel: { socket.connection.cancel() }
    }
    @MainActor func pair(_ code: String) async throws {
        let invite = try DeviceInvitation.parse(code)
        guard invite.id != id, peers[invite.id] == nil, peers.count < 20, let secret = Data(base64Encoded: invite.secret) else { throw DeviceError.invalid }
        let key = DeviceWire.randomKey(), current = generation
        let peer = DevicePeer(id: invite.id, name: invite.name, host: invite.host, port: invite.port)
        try await use(peer, key: secret, pair: true) { channel in
            try await channel.send(DeviceMessage(op: "pair", id: id, name: name, port: port, key: key.base64EncodedString()))
            let reply = try await channel.reply()
            guard reply.ok, reply.id == invite.id, current == generation, await persist(peer, key) else { throw DeviceError.declined }
            peers[peer.id] = (peer, key); changed()
        }
    }
    @MainActor func send(_ id: String, text: String? = nil, file: URL? = nil, progress: @escaping (Int) -> Void = { _ in }) async throws {
        guard let trusted = peers[id] else { throw DeviceError.declined }
        try await use(trusted.0, key: trusted.1, pair: false) { channel in
            guard let file else {
                if let text, text.utf16.count > 16000 { throw DeviceError.invalid }
                try await channel.send(DeviceMessage(op: text == nil ? "ping" : "text", text: text)); try await channel.checkReply(); return
            }
            try DeviceWire.validateName(file.lastPathComponent)
            let (handle, length) = try await disk.open(file)
            do {
                guard (0...DeviceWire.maxFile).contains(length) else { throw DeviceError.invalid }
                try await channel.send(DeviceMessage(op: "file", name: file.lastPathComponent, size: length)); try await channel.checkReply()
                var sent: Int64 = 0, percent = -1
                while sent < length {
                    let bytes = try await disk.read(handle, count: Int(min(Int64(DeviceWire.chunk), length - sent)))
                    guard !bytes.isEmpty else { throw DeviceError.invalid }
                    try await channel.send(bytes); sent += Int64(bytes.count)
                    let next = Int(sent * 100 / max(1, length)); if next != percent { percent = next; progress(next) }
                }
                await disk.close(handle); try await channel.checkReply()
            } catch { await disk.close(handle); throw error }
        }
    }
    func stop() {
        generation = UUID(); invitation = nil; listener?.cancel(); listener = nil; port = 0
        for socket in sockets.values { socket.close() }
    }
}
