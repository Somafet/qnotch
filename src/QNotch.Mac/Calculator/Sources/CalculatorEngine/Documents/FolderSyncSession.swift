import CoreServices
import Foundation

/// Event-driven lifecycle around `FolderSync`. Nothing exists until a folder is configured: no watcher, timer or task.
/// When on, folder notifications and host requests restart one debounce timer; a pass scans on a background queue,
/// then applies through `post` on the store's thread. Retries are one-shot and bounded; there is no polling loop.
/// Windows watches with FileSystemWatcher and a thread-pool Timer; the Mac uses an FSEvents stream (file-level events for
/// `*.calcsheet` directly inside the folder) and a dispatch timer.
final class FolderSyncSession {
    /// Seconds.
    static let debounce = 0.75, maxDelay = 5.0, retryDelay = 5.0
    static let maxRetries = 6
    private static let counter = NSLock()
    private static var watchers = 0
    /// Process-wide count of folder watchers, so tests and diagnostics can prove an off setting creates none.
    static var liveWatchers: Int { counter.lock(); defer { counter.unlock() }; return watchers }
    private static func countWatcher(_ delta: Int) { counter.lock(); watchers += delta; counter.unlock() }

    private let gate = NSRecursiveLock()
    private let store: WorkspaceStore
    private let dataDirectory: String
    private let engine: FolderSync
    private let post: (@escaping () -> Void) -> Void
    private let canApply: () -> Bool
    private let completed: (SyncReport) -> Void
    private var watcher: FolderWatcher?
    private var timer: DispatchSourceTimer?
    private var firstRequest: DispatchTime?
    private var running = false, again = false, disposed = false
    private var retries = 0
    private var configuredFolder: String?
    private var passCount = 0
    var folder: String? { locked { configuredFolder } }
    var watching: Bool { locked { watcher != nil } }
    var timerExists: Bool { locked { timer != nil } }
    var passes: Int { locked { passCount } }

    /// - Parameters:
    ///   - post: Runs an action on the thread that owns `store`.
    ///   - canApply: Called on that thread before applying; false (for example while composing or after a failed save) defers the pass.
    init(_ store: WorkspaceStore, _ dataDirectory: String, _ device: String, post: @escaping (@escaping () -> Void) -> Void, canApply: @escaping () -> Bool,
         completed: @escaping (SyncReport) -> Void, clock: (() -> DateTimeOffset)? = nil) {
        self.store = store; self.dataDirectory = dataDirectory; self.post = post; self.canApply = canApply; self.completed = completed
        engine = FolderSync(store, device, clock: clock)
    }

    private func locked<T>(_ body: () -> T) -> T { gate.lock(); defer { gate.unlock() }; return body() }

    /// Reads the configured folder and, only if one is set, starts watching and requests a first pass.
    func start() throws { configure(try FolderSync.configuredFolder(dataDirectory)) }

    func setFolder(_ folder: String?) throws {
        try FolderSync.setFolder(dataDirectory, folder)
        configure(try FolderSync.configuredFolder(dataDirectory))
    }

    private func configure(_ folder: String?) {
        let started: Bool = locked {
            if disposed { return false }
            stopLocked()
            configuredFolder = folder
            guard let folder else { return false }
            watchLocked(folder)
            return true
        }
        if started { request() }
    }

    /// An unavailable folder gets no watcher: the pass reports it, and the next pass that finds it available installs one.
    private func watchLocked(_ folder: String) {
        watcher = FolderWatcher(folder) { [weak self] in self?.request() }
        if watcher != nil { FolderSyncSession.countWatcher(1) }
    }

    /// Coalesces requests: waits for a quiet `debounce`, but never longer than `maxDelay` after the first.
    func request() { schedule(FolderSyncSession.debounce, request: true) }

    /// `request`: a change request, coalesced under `maxDelay`. A retry or recheck keeps its own delay.
    private func schedule(_ delay: Double, request: Bool) {
        gate.lock(); defer { gate.unlock() }
        if disposed || configuredFolder == nil { return }
        if request { retries = 0 }
        if running { again = true; return }
        var wait = delay
        if request {
            let now = DispatchTime.now()
            if firstRequest == nil { firstRequest = now }
            let latest = FolderSyncSession.maxDelay - Double(now.uptimeNanoseconds - firstRequest!.uptimeNanoseconds) / 1e9
            if latest < wait { wait = max(0, latest) }
        }
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: .global())
            source.setEventHandler { [weak self] in self?.fire() }
            source.schedule(deadline: .now() + wait)
            source.resume()
            timer = source
        } else { timer!.schedule(deadline: .now() + wait) }
    }

    private func fire() {
        let folder: String? = locked {
            if disposed || configuredFolder == nil || running { return nil }
            running = true; again = false; firstRequest = nil
            return configuredFolder
        }
        guard let folder else { return }
        let snapshot = engine.scan(folder)
        post { [self] in apply(snapshot) }
    }

    private func apply(_ snapshot: SyncFolderSnapshot) {
        var report: SyncReport?
        defer { finish(report) }
        if locked({ disposed }) { return }
        if !canApply() { report = nil; return }
        locked { passCount += 1 }
        do { report = try engine.synchronize(snapshot) }
        catch {
            // C# catches IO, access, data and JSON failures here; anything else would end the process, so it is reported the same way.
            var failed = SyncReport(.failed, nil, []); failed.problem = error.netMessage; report = failed
        }
        completed(report!)
    }

    private func finish(_ report: SyncReport?) {
        gate.lock(); defer { gate.unlock() }
        running = false; var rerun = again; again = false; var delay: Double?
        if !disposed, watcher == nil, let folder = configuredFolder, let report, report.status != .folderUnavailable, report.status != .off {
            watchLocked(folder)
            if watcher != nil { rerun = true } // A file that arrived between this pass's scan and the watcher would go unseen.
        }
        if !rerun, let report {
            if report.retrySoon && retries < FolderSyncSession.maxRetries { retries += 1; delay = FolderSyncSession.retryDelay }
            else if let after = report.recheckAfter { delay = Double(after) / Double(Ticks.perSecond) + 1 }
        } else if !rerun && report == nil && retries < FolderSyncSession.maxRetries { retries += 1; delay = FolderSyncSession.retryDelay }
        // Armed under the lock (recursive): a change request arriving after this replaces a long recheck, never the other way round.
        if rerun { request() } else if let delay { schedule(delay, request: false) }
    }

    private func stopLocked() {
        if let watcher {
            watcher.stop(); self.watcher = nil
            FolderSyncSession.countWatcher(-1)
        }
        timer?.cancel(); timer = nil; firstRequest = nil; again = false
    }

    /// `Dispose`.
    func dispose() {
        gate.lock(); defer { gate.unlock() }
        if disposed { return }
        disposed = true; stopLocked(); configuredFolder = nil
    }
    deinit { dispose() }
}

/// An FSEvents stream on one folder that reports changes to `*.calcsheet` files directly inside it (FileSystemWatcher with
/// IncludeSubdirectories = false). Dropped or coalesced events count as a change, as FileSystemWatcher's Error event does.
private final class FolderWatcher {
    private final class Box { let folder: String; let changed: () -> Void; init(_ folder: String, _ changed: @escaping () -> Void) { self.folder = folder; self.changed = changed } }
    private var stream: FSEventStreamRef?
    private let box: Box

    init?(_ folder: String, _ changed: @escaping () -> Void) {
        guard NetFile.directoryExists(folder) else { return nil }
        let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        box = Box(real, changed)
        // The stream retains the box, so a callback already queued when the stream stops still finds it.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: { info in info.map { _ = Unmanaged<Box>.fromOpaque($0).retain() }; return info },
                                           release: { info in info.map { Unmanaged<Box>.fromOpaque($0).release() } }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let overflow = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            for i in 0..<count {
                if flags[i] & overflow != 0 { box.changed(); return }
                let path = URL(fileURLWithPath: String(cString: names[i]))
                if path.deletingLastPathComponent().resolvingSymlinksInPath().path == box.folder && path.lastPathComponent.endsWithIgnoreCase(SyncFolderFiles.extension) {
                    box.changed(); return
                }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, callback, &context, [real] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return nil }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global())
        guard FSEventStreamStart(created) else { FSEventStreamInvalidate(created); FSEventStreamRelease(created); return nil }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }
    deinit { stop() }
}
