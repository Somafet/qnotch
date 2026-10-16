import AppKit
import CoreServices
import QNotchMacCore
import SQLite3

/// T3 Code's sessions and thread titles, from its own database (~/.t3/userdata/statev2.sqlite),
/// opened read-only so T3 keeps writing. An FSEvents stream on the folder (1-second latency, so at
/// most one read a second) reports writes to the database and its WAL; nothing polls. Reads happen
/// only while T3 Code runs.
final class T3Watch {
    static let bundleID = "com.t3tools.t3code"
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata", isDirectory: true)

    private let queue = DispatchQueue(label: "qnotch.agents.t3", qos: .utility)
    private var stream: FSEventStreamRef?
    private var observers: [NSObjectProtocol] = []
    private var pending = false
    private let changed: ([T3Session], [String: String]) -> Void

    init(changed: @escaping ([T3Session], [String: String]) -> Void) {
        self.changed = changed
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == Self.bundleID { self?.schedule() }
            })
        }
        startStream()
        schedule()
    }

    deinit { stop() }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    private func startStream() {
        // Watch the nearest existing folder, so a later T3 install is noticed too.
        var path = Self.folder
        while !FileManager.default.fileExists(atPath: path.path), path.pathComponents.count > 2 { path = path.deletingLastPathComponent() }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<T3Watch>.fromOpaque(info).takeUnretainedValue()
            let names = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            // Reading SQLite touches its -shm file; that alone carries no new sessions.
            if names.prefix(count).contains(where: { $0.hasSuffix("statev2.sqlite") || $0.hasSuffix("statev2.sqlite-wal") || !$0.hasPrefix(T3Watch.folder.path) }) {
                DispatchQueue.main.async { watch.schedule() }
            }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func schedule() {
        guard !pending else { return }
        pending = true
        let running = isRunning
        queue.async { [weak self] in
            guard let self else { return }
            let database = Self.folder.appendingPathComponent("statev2.sqlite").path
            var sessions: [T3Session] = []
            var titles: [String: String] = [:]
            if running, FileManager.default.fileExists(atPath: database) {
                let environment = (try? String(contentsOf: Self.folder.appendingPathComponent("environment-id"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let rows = Self.rows(database, T3Session.query) { sessions = rows.compactMap { T3Session.from(row: $0, environment: environment) } }
                for row in Self.rows(database, T3Session.titlesQuery) ?? [] where row.count == 2 && !row[0].isEmpty {
                    titles[row[0]] = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            DispatchQueue.main.async {
                self.pending = false
                self.changed(sessions, titles)
            }
        }
    }

    /// One short read-only snapshot; nil (not a partial result) on a busy or changed database.
    static func rows(_ path: String, _ query: String) -> [[String]]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { return nil }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }
}
