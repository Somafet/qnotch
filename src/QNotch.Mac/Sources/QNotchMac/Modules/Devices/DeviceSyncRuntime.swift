import AppKit
import Network

/// Main-thread coordinator, with serialized disk work and event-driven retry scheduling.
final class DeviceSyncRuntime {
    private let context: ModuleContext
    private let peers: () -> [DevicePeer]
    private let node: () -> DeviceNode?
    private let path: URL
    private let io = DispatchQueue(label: "qnotch.devices.sync", qos: .utility)
    private var state: DeviceSync
    private var loaded = false, failed = false, applying = false, working = false, again = false, stopped = false
    private var lastNote: String?
    private var attempts = 0
    private var pending: DispatchWorkItem?
    private var pendingSave: DispatchWorkItem?
    private let network = NWPathMonitor()
    private var attached: [String: ObjectIdentifier] = [:]
    private(set) var status = "Sync is off for new devices. Enable it separately on both computers."
    var changed: () -> Void = {}
    var conflicts: [NoteRevision] { state.journal.notes.count > 1 ? state.journal.notes : [] }
    var isReady: Bool { loaded && !failed }
    init(context: ModuleContext, deviceID: String, peers: @escaping () -> [DevicePeer], node: @escaping () -> DeviceNode?) {
        self.context = context; self.peers = peers; self.node = node
        path = context.settings.directory.appendingPathComponent("devices-sync.json")
        state = DeviceSync(deviceID: deviceID)
        guard !Runtime.diagnostics else { loaded = true; return }
        context.registries.sharedText.changed = { [weak self] in self?.attach() }
        attach()
        network.pathUpdateHandler = { [weak self] _ in DispatchQueue.main.async { [weak self] in self?.schedule(1) } }
        network.start(queue: io)
        let path = path
        io.async { [weak self] in
            do {
                let journal: SyncJournal
                if FileManager.default.fileExists(atPath: path.path) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                    guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= DeviceWire.maxSync else { throw DeviceError.invalid }
                    let bytes = try Data(contentsOf: path)
                    journal = try JSONDecoder().decode(SyncJournal.self, from: bytes)
                    _ = try DeviceSync.merge(journal.notes, [])
                    guard journal.activeClock.count <= DeviceSync.maxAuthors, journal.clipboardCounter >= 0 else { throw DeviceError.invalid }
                } else { journal = SyncJournal() }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.state = DeviceSync(deviceID: deviceID, journal: journal); self.loaded = true; self.configure()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }; self.failed = true
                    self.status = "Saved sync data could not be read. Sync is paused; your note and journal have been preserved."
                    self.changed()
                }
            }
        }
    }
    private func source(_ id: String) -> SharedTextSource? { context.registries.sharedText.items.first { $0.id == id } }
    private var notesOn: Bool { peers().contains { $0.receive && $0.syncNotes } }
    private var clipsOn: Bool { peers().contains { $0.receive && $0.syncClipboard } }
    private func attach() {
        let sources = context.registries.sharedText.items
        attached = attached.filter { key, _ in sources.contains { $0.id == key } }
        for source in sources where attached[source.id] != ObjectIdentifier(source) {
            attached[source.id] = ObjectIdentifier(source)
            source.changed = { [weak self, weak source] text in guard let source else { return }; self?.localChanged(source.id, text) }
        }
        configure()
    }
    func configure() {
        guard loaded, !failed, !stopped, !Runtime.diagnostics else { return }
        do {
            if notesOn, let text = source("note")?.read(), text != lastNote {
                if lastNote == nil { try state.reconcileEditor(text) } else { try state.editNote(text) }
                lastNote = text; persist()
            }
            if !conflicts.isEmpty { status = "Note conflict: both versions are preserved. Choose a version below to resolve it." }
            schedule(1); changed()
        } catch { status = "Note sync limit reached. Resolve any conflicts before syncing more versions."; changed() }
    }
    private func localChanged(_ id: String, _ text: String) {
        guard loaded, !failed, !applying, !stopped, !Runtime.diagnostics else { return }
        do {
            if id == "note", notesOn {
                if lastNote == nil { try state.reconcileEditor(text) }
                else if lastNote != text { try state.editNote(text) }
                else { return }
                lastNote = text
            } else if id == "clipboard", clipsOn { try state.copyText(text) }
            else { return }
            persist(); attempts = 0; schedule(1); changed()
        } catch { status = "Text exceeds a sync limit, or too many note versions need resolution."; changed() }
    }
    private func bundle(_ peer: DevicePeer) -> SyncBundle {
        state.bundle(notes: peer.syncNotes && source("note")?.read() != nil, clips: peer.syncClipboard && source("clipboard") != nil)
    }
    private func fingerprint() -> String {
        state.journal.notes.map(\.id).joined(separator: ",") + ":\(state.journal.clipboardCounter):" + state.journal.clipboardAuthor
    }
    private func merge(_ peer: DevicePeer, _ incoming: SyncBundle) throws {
        let before = fingerprint(), candidate = state.clone()
        var note: String?, clip: String?
        if peer.syncNotes, incoming.notesEnabled, source("note")?.read() != nil { note = try candidate.receiveNotes(incoming.notes) }
        if peer.syncClipboard, incoming.clipboardEnabled, source("clipboard") != nil { clip = try candidate.receiveClipboard(incoming.clipboard) }
        applying = true
        defer { applying = false }
        if let note, let source = source("note"), source.read() != note { source.apply(note); lastNote = note }
        if let clip { source("clipboard")?.apply(clip) }
        state = candidate
        if before != fingerprint() { persist(); schedule(1) }
        status = conflicts.isEmpty ? "Sync is up to date." : "Note conflict: both versions are preserved. Choose a version below to resolve it."
        changed()
    }
    @MainActor func exchange(_ id: String, input: Data) async throws -> Data {
        guard loaded, !failed, !stopped, let peer = peers().first(where: { $0.id == id && $0.receive }) else { throw DeviceError.unavailable }
        let incoming = try JSONDecoder().decode(SyncBundle.self, from: input)
        try merge(peer, incoming); return try JSONEncoder().encode(bundle(peer))
    }
    func resolve(_ id: String) {
        guard loaded, !failed, !Runtime.diagnostics, let source = source("note"), let selected = state.journal.notes.first(where: { $0.id == id }) else { return }
        do {
            let candidate = state.clone(); try candidate.editNote(selected.text, resolveAll: true)
            applying = true; source.apply(selected.text); lastNote = selected.text; applying = false
            state = candidate; persist(); status = "Note conflict resolved. The chosen version will sync."; schedule(1); changed()
        } catch { applying = false; status = "Could not resolve the note conflict."; changed() }
    }
    private func schedule(_ seconds: Int) {
        guard loaded, !failed, !stopped, !Runtime.diagnostics, (node()?.port ?? 0) > 0,
              peers().contains(where: { $0.receive && ($0.syncNotes || $0.syncClipboard) }) else { return }
        if working { again = true; return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in Task { @MainActor [weak self] in await self?.pump() } }
        pending = item; DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: item)
    }
    @MainActor private func pump() async {
        guard !working, !stopped, !failed, let active = node(), active.port > 0 else { return }
        working = true; again = false
        var hadFailure = false
        for peer in peers().filter({ $0.receive && ($0.syncNotes || $0.syncClipboard) }) {
            guard !stopped, node() === active else { working = false; return }
            do {
                let payload = try JSONEncoder().encode(bundle(peer))
                let response = try await active.synchronize(peer.id, payload: payload)
                if node() === active, let current = peers().first(where: { $0.id == peer.id && $0.receive }) {
                    try merge(current, JSONDecoder().decode(SyncBundle.self, from: response))
                }
            } catch { hadFailure = true; status = "A device is offline or sync is unavailable. Notes are kept locally and will retry."; changed() }
        }
        working = false
        if hadFailure { attempts = min(attempts + 1, 6); schedule(min(300, 5 * (1 << attempts))) }
        else { attempts = 0; if again { schedule(1) } }
    }
    private func persist() {
        guard !Runtime.diagnostics, !failed, !stopped else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
    private func saveNow() {
        guard !Runtime.diagnostics, !failed, !stopped else { return }
        let snapshot = state.journal, path = path
        io.async { [weak self] in
            do { try JSONEncoder().encode(snapshot).write(to: path, options: .atomic) }
            catch { DispatchQueue.main.async { [weak self] in self?.status = "Sync changes could not be saved. Keep QNotch open and check its data folder."; self?.changed() } }
        }
    }
    func stop() {
        pending?.cancel(); pendingSave?.cancel(); network.cancel(); context.registries.sharedText.changed = nil
        if loaded, !failed, !Runtime.diagnostics {
            let snapshot = state.journal, path = path
            io.sync { try? JSONEncoder().encode(snapshot).write(to: path, options: .atomic) }
        }
        stopped = true
    }
}
