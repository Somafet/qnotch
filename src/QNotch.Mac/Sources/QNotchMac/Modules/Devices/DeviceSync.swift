import Foundation

struct NoteRevision: Codable, Equatable, Sendable {
    let id: String
    let clock: [String: Int64]
    let text: String
}
struct ClipboardRevision: Codable, Sendable {
    let counter: Int64
    let author: String
    let text: String
}
struct SyncBundle: Codable, Sendable {
    let notesEnabled: Bool
    let clipboardEnabled: Bool
    let notes: [NoteRevision]
    let clipboard: ClipboardRevision?
}
struct SyncJournal: Codable, Sendable {
    var notes: [NoteRevision] = []
    var activeClock: [String: Int64] = [:]
    var clipboardCounter: Int64 = 0
    var clipboardAuthor = ""
}

/// Swift 5.9 nonisolated async work runs off the main actor; large snapshots never decode there.
enum DeviceSyncCodec {
    static func decode(_ bytes: Data) async throws -> SyncBundle { try JSONDecoder().decode(SyncBundle.self, from: bytes) }
    static func encode(_ bundle: SyncBundle) async throws -> Data { try JSONEncoder().encode(bundle) }
}

/// Native counterpart of DeviceSync.cs. State lives on the module's main actor.
final class DeviceSync {
    static let maxNoteChars = 100000, maxBranches = 8, maxAuthors = 64
    let deviceID: String
    private(set) var journal: SyncJournal
    private(set) var clipboard: ClipboardRevision?
    init(deviceID: String, journal: SyncJournal = SyncJournal()) { self.deviceID = deviceID; self.journal = journal }
    func clone() -> DeviceSync { let copy = DeviceSync(deviceID: deviceID, journal: journal); copy.clipboard = clipboard; return copy }
    @discardableResult func reconcileEditor(_ text: String) throws -> Bool {
        guard text.utf16.count <= Self.maxNoteChars else { throw DeviceError.invalid }
        if let existing = journal.notes.first(where: { $0.text == text }) { journal.activeClock = existing.clock; return false }
        if journal.notes.isEmpty { if text.isEmpty { return false }; return try editNote(text) }
        let recovery = NoteRevision(id: UUID().uuidString.lowercased(), clock: [UUID().uuidString.lowercased(): 1], text: text)
        journal.notes = try Self.merge(journal.notes, [recovery]); journal.activeClock = recovery.clock; return true
    }
    static func includes(_ a: [String: Int64], _ b: [String: Int64]) -> Bool { b.allSatisfy { a[$0.key, default: 0] >= $0.value } }
    static func validateJournal(_ journal: SyncJournal) throws {
        _ = try merge(journal.notes, [])
        guard journal.activeClock.count <= maxAuthors,
              journal.activeClock.allSatisfy({ DeviceWire.validID($0.key) && $0.value > 0 && $0.value < 9007199254740991 }),
              journal.clipboardCounter >= 0, journal.clipboardCounter < 9007199254740991,
              journal.clipboardCounter == 0 || DeviceWire.validID(journal.clipboardAuthor) else { throw DeviceError.invalid }
    }
    static func validate(_ item: NoteRevision) throws {
        guard DeviceWire.validID(item.id), item.text.utf16.count <= maxNoteChars, (1...maxAuthors).contains(item.clock.count),
              item.clock.allSatisfy({ DeviceWire.validID($0.key) && $0.value > 0 && $0.value < 9007199254740991 }) else { throw DeviceError.invalid }
    }
    static func merge(_ left: [NoteRevision], _ right: [NoteRevision]) throws -> [NoteRevision] {
        let all = left + right
        guard all.count <= maxBranches * 2 else { throw DeviceError.invalid }
        var unique: [String: NoteRevision] = [:]
        for item in all {
            try validate(item)
            if let existing = unique[item.id], existing != item { throw DeviceError.invalid }
            unique[item.id] = item
        }
        let values = Array(unique.values)
        for i in values.indices {
            for j in values.indices where j > i {
                if values[i].clock == values[j].clock { throw DeviceError.invalid }
            }
        }
        let result = values.filter { item in !values.contains { $0.id != item.id && includes($0.clock, item.clock) } }.sorted { $0.id < $1.id }
        guard result.count <= maxBranches else { throw DeviceError.invalid }
        return result
    }
    private static func join(_ clocks: [[String: Int64]]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for clock in clocks { for (key, value) in clock { result[key] = max(result[key, default: 0], value) } }
        return result
    }
    @discardableResult func editNote(_ text: String, resolveAll: Bool = false) throws -> Bool {
        guard text.utf16.count <= Self.maxNoteChars else { throw DeviceError.invalid }
        if !resolveAll, journal.notes.count == 1, journal.notes[0].text == text {
            journal.activeClock = journal.notes[0].clock; return false
        }
        var clock = resolveAll ? Self.join(journal.notes.map(\.clock) + [journal.activeClock]) : journal.activeClock
        let own = (journal.notes.map { $0.clock[deviceID, default: 0] } + [clock[deviceID, default: 0]]).max() ?? 0
        guard own < 9007199254740990 else { throw DeviceError.invalid }
        clock[deviceID] = own + 1
        let next = NoteRevision(id: UUID().uuidString.lowercased(), clock: clock, text: text)
        let merged = try Self.merge(journal.notes, [next])
        journal.notes = merged; journal.activeClock = clock; return true
    }
    func receiveNotes(_ remote: [NoteRevision]) throws -> String? {
        journal.notes = try Self.merge(journal.notes, remote)
        guard journal.notes.count == 1 else { return nil }
        journal.activeClock = journal.notes[0].clock; return journal.notes[0].text
    }
    func copyText(_ text: String) throws {
        guard text.utf16.count <= 16000, journal.clipboardCounter < 9007199254740990 else { throw DeviceError.invalid }
        journal.clipboardCounter += 1; journal.clipboardAuthor = deviceID
        clipboard = ClipboardRevision(counter: journal.clipboardCounter, author: deviceID, text: text)
    }
    func receiveClipboard(_ incoming: ClipboardRevision?) throws -> String? {
        guard let incoming else { return nil }
        guard incoming.counter > 0, incoming.counter < 9007199254740991, DeviceWire.validID(incoming.author), incoming.text.utf16.count <= 16000 else { throw DeviceError.invalid }
        guard incoming.counter > journal.clipboardCounter || (incoming.counter == journal.clipboardCounter && incoming.author > journal.clipboardAuthor) else { return nil }
        journal.clipboardCounter = incoming.counter; journal.clipboardAuthor = incoming.author; clipboard = incoming
        return incoming.text
    }
    func bundle(notes: Bool, clips: Bool) -> SyncBundle {
        SyncBundle(notesEnabled: notes, clipboardEnabled: clips, notes: notes ? journal.notes : [], clipboard: clips ? clipboard : nil)
    }
}
