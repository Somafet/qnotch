import Foundation

/// .NET exception types the documents layer distinguishes beyond `CalcError` (which keeps InvalidDataException,
/// InvalidOperationException and ArgumentException). Messages are shown to the user like `Exception.Message`.
enum DocumentError: Error, Equatable, CustomStringConvertible {
    /// IOException.
    case io(String)
    /// FileNotFoundException, an IOException.
    case fileNotFound(String)
    /// DirectoryNotFoundException, an IOException.
    case directoryNotFound(String)
    /// UnauthorizedAccessException (not an IOException): permissions, read-only or locked (immutable) files.
    case unauthorized(String)
    /// System.Text.Json's JsonException (not an IOException).
    case json(String)
    /// Calc.Documents.UnsupportedDocumentVersionException, an IOException.
    case unsupportedVersion
    /// Calc.Documents.ImportRejectedException, an IOException.
    case importRejected(String)
    /// Calc.Documents.ShareLinkException.
    case shareLink(String)

    var message: String {
        switch self {
        case .io(let m), .fileNotFound(let m), .directoryNotFound(let m), .unauthorized(let m), .json(let m), .importRejected(let m), .shareLink(let m): return m
        case .unsupportedVersion: return "Unsupported document version; original preserved"
        }
    }
    var description: String { message }
}

extension Error {
    /// `e is IOException`.
    var isIOException: Bool {
        if let e = self as? DocumentError {
            switch e { case .io, .fileNotFound, .directoryNotFound, .unsupportedVersion, .importRejected: return true; default: return false }
        }
        if let e = self as? CalcError, case .io = e { return true }
        return false
    }
    var isUnsupportedVersion: Bool { (self as? DocumentError) == .unsupportedVersion }
    var isUnauthorized: Bool { if case .unauthorized? = self as? DocumentError { return true }; return false }
    var isJsonError: Bool { if case .json? = self as? DocumentError { return true }; return false }
    var isFileNotFound: Bool { if case .fileNotFound? = self as? DocumentError { return true }; return false }
    var isDirectoryNotFound: Bool { if case .directoryNotFound? = self as? DocumentError { return true }; return false }
    var isShareLinkError: Bool { if case .shareLink? = self as? DocumentError { return true }; return false }
    var isImportRejected: Bool { if case .importRejected? = self as? DocumentError { return true }; return false }
    /// `e is InvalidDataException`.
    var isInvalidData: Bool { if case .invalidData? = self as? CalcError { return true }; return false }
    /// `e is InvalidOperationException`.
    var isInvalidOperation: Bool { if case .invalidOperation? = self as? CalcError { return true }; return false }
    /// `e is ArgumentException`.
    var isArgumentError: Bool { (self as? CalcError)?.isArgument == true }
    /// The `Exception.Message` C# would show.
    var netMessage: String {
        if let e = self as? DocumentError { return e.message }
        if let e = self as? CalcError { return e.message }
        return localizedDescription
    }
}

/// The parts of .NET's File, Directory and FileInfo that documents use, on POSIX calls so failures map onto .NET's
/// exception types. Windows sharing is reproduced with advisory `flock` locks:
/// - an open with `FileShare.Read` (readers: AtomicJson, tests) takes a shared lock for the duration of the read;
/// - an open with `FileShare.None` (session.lock, tests) takes an exclusive lock;
/// - replacing or moving over a file first probes for an exclusive lock, so a reader or a holder blocks the replacement as it
///   does on Windows (File.Replace and File.Move need delete access the holder did not share);
/// - a destination without write permission refuses replacement with UnauthorizedAccess, like the Windows read-only attribute,
///   and an immutable (Finder "Locked") file is refused by the kernel itself.
enum NetFile {
    // MARK: Errors

    static func error(_ code: Int32, _ path: String, directory: Bool = false) -> DocumentError {
        let reason = String(cString: strerror(code))
        switch code {
        case ENOENT:
            let parent = (path as NSString).deletingLastPathComponent
            if directory || !directoryExists(parent) { return .directoryNotFound("Could not find a part of the path '\(path)'.") }
            return .fileNotFound("Could not find file '\(path)'.")
        case EACCES, EPERM, EROFS: return .unauthorized("Access to the path '\(path)' is denied.")
        case EWOULDBLOCK: return .io("The process cannot access the file '\(path)' because it is being used by another process.")
        case EEXIST: return .io("The file '\(path)' already exists.")
        default: return .io("\(reason): '\(path)'")
        }
    }
    private static func check(_ result: Int32, _ path: String) throws { if result != 0 { throw error(errno, path) } }

    // MARK: Queries

    static func status(_ path: String) -> stat? {
        var info = stat()
        return stat(path, &info) == 0 ? info : nil
    }
    /// `File.Exists`: a file (not a directory) is there.
    static func fileExists(_ path: String) -> Bool { status(path).map { $0.st_mode & S_IFMT != S_IFDIR } ?? false }
    /// `Directory.Exists`.
    static func directoryExists(_ path: String) -> Bool { status(path).map { $0.st_mode & S_IFMT == S_IFDIR } ?? false }

    /// `FileInfo`: existence, length, last write time (DateTime ticks, UTC) and the BSD flags (st_flags).
    struct Info {
        let exists: Bool, isDirectory: Bool, length: Int64, lastWriteTicks: Int64, flags: UInt32, mode: mode_t
    }
    static func info(_ path: String) -> Info {
        guard let s = status(path) else { return Info(exists: false, isDirectory: false, length: 0, lastWriteTicks: 0, flags: 0, mode: 0) }
        let ticks = Ticks.unixEpoch + Int64(s.st_mtimespec.tv_sec) * Ticks.perSecond + Int64(s.st_mtimespec.tv_nsec) / 100
        return Info(exists: true, isDirectory: s.st_mode & S_IFMT == S_IFDIR, length: Int64(s.st_size), lastWriteTicks: ticks, flags: s.st_flags, mode: s.st_mode)
    }
    /// `File.SetLastWriteTimeUtc`.
    static func setLastWriteTicks(_ path: String, _ ticks: Int64) throws {
        let since = ticks - Ticks.unixEpoch
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(since / Ticks.perSecond), tv_nsec: Int(since % Ticks.perSecond) * 100)]
        try check(utimensat(AT_FDCWD, path, &times, 0), path)
    }

    /// Entry names directly inside a folder (no recursion), files or directories.
    static func entries(_ directory: String) throws -> [String] {
        guard let handle = opendir(directory) else { throw error(errno, directory, directory: true) }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
    /// `Directory.EnumerateFiles(directory)`: full paths of the files directly inside.
    static func files(_ directory: String) throws -> [String] {
        try entries(directory).map { (directory as NSString).appendingPathComponent($0) }.filter(fileExists)
    }
    /// `Directory.EnumerateDirectories(directory)`.
    static func directories(_ directory: String) throws -> [String] {
        try entries(directory).map { (directory as NSString).appendingPathComponent($0) }.filter(directoryExists)
    }

    // MARK: Changes

    /// `Directory.CreateDirectory`: creates every missing folder; a file in the way is an IOException.
    static func createDirectory(_ path: String) throws {
        if directoryExists(path) { return }
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != path && !directoryExists(parent) { try createDirectory(parent) }
        if mkdir(path, 0o755) != 0 {
            let code = errno
            if code == EEXIST && directoryExists(path) { return }
            throw code == EEXIST ? DocumentError.io("Cannot create '\(path)' because a file with the same name already exists.") : error(code, path)
        }
    }
    /// `File.Delete`: a missing file is not an error.
    static func delete(_ path: String) throws {
        if unlink(path) != 0 {
            let code = errno
            if code == ENOENT { return }
            throw code == EPERM && directoryExists(path) ? DocumentError.unauthorized("Access to the path '\(path)' is denied.") : error(code, path)
        }
    }
    /// `Directory.Delete(path)` of an empty folder.
    static func deleteDirectory(_ path: String) throws { try check(rmdir(path), path) }
    /// `Directory.Delete(path, true)`.
    static func deleteTree(_ path: String) throws {
        guard directoryExists(path) else { try delete(path); return }
        for entry in try entries(path) { try deleteTree((path as NSString).appendingPathComponent(entry)) }
        try deleteDirectory(path)
    }

    /// Fails like Windows when someone holds the file open without sharing delete access (here: holds any flock).
    static func requireReplaceable(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd < 0 {
            let code = errno
            if code == ENOENT { return }
            if code == EACCES { throw DocumentError.unauthorized("Access to the path '\(path)' is denied.") }
            throw error(code, path)
        }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { throw error(errno, path) }
        flock(fd, LOCK_UN)
        // The Windows read-only attribute refuses replacement; POSIX rename ignores the file's own mode, so check it here.
        if access(path, W_OK) != 0 && errno == EACCES { throw DocumentError.unauthorized("Access to the path '\(path)' is denied.") }
    }

    /// `File.Move(source, destination, overwrite)`. Without overwrite an existing destination (even a folder) is an IOException.
    static func move(_ source: String, _ destination: String, overwrite: Bool) throws {
        if overwrite {
            if directoryExists(destination) { throw DocumentError.unauthorized("Access to the path '\(destination)' is denied.") }
            try requireReplaceable(destination)
            try check(rename(source, destination), source)
        } else {
            if status(destination) != nil { throw DocumentError.io("Cannot create a file when that file already exists: '\(destination)'.") }
            if renamex_np(source, destination, UInt32(RENAME_EXCL)) != 0 {
                let code = errno
                throw code == EEXIST ? DocumentError.io("Cannot create a file when that file already exists: '\(destination)'.") : error(code, source)
            }
        }
    }

    /// `File.Replace(source, destination, backup)`: the destination takes the source's content and its previous content becomes the
    /// backup. On APFS and HFS+ the destination name is swapped atomically (it never goes missing); elsewhere it is hard-linked to the
    /// backup before the rename.
    static func replace(_ source: String, _ destination: String, backup: String) throws {
        guard fileExists(destination) else { throw error(ENOENT, destination) }
        try requireReplaceable(destination)
        if fileExists(backup) { try requireReplaceable(backup) }
        if renamex_np(source, destination, UInt32(RENAME_SWAP)) == 0 {
            // The source name now holds the previous content.
            try check(rename(source, backup), source)
            return
        }
        let code = errno
        guard code == ENOTSUP || code == EINVAL || code == EXDEV else { throw error(code, destination) }
        let link = backup + "." + UUID.netNew().netN + ".link"
        if Darwin.link(destination, link) == 0 {
            defer { _ = unlink(link) }
            try check(rename(link, backup), link)
        } else {
            try copy(destination, backup, overwrite: true)
        }
        try check(rename(source, destination), source)
    }

    /// `File.Copy(source, destination, overwrite)`.
    static func copy(_ source: String, _ destination: String, overwrite: Bool = false) throws {
        let bytes = try readAll(source)
        if !overwrite && status(destination) != nil { throw DocumentError.io("The file '\(destination)' already exists.") }
        let temporary = destination + "." + UUID.netNew().netN + ".copy"
        defer { try? delete(temporary) }
        try writeNew(temporary, bytes, flush: false)
        if overwrite { try move(temporary, destination, overwrite: true) } else { try move(temporary, destination, overwrite: false) }
    }

    // MARK: Contents

    /// Reads a whole file as `new FileStream(path, Open, Read, FileShare.Read)` would: a holder of an exclusive lock makes it fail.
    /// `limit` refuses a larger file before reading; `changed` is thrown if the file grows while it is read.
    static func readAll(_ path: String, limit: Int64? = nil, tooLarge: Error? = nil, changed: Error? = nil) throws -> [UInt8] {
        let fd = open(path, O_RDONLY)
        if fd < 0 { throw error(errno, path) }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) != 0 { throw error(errno, path) }
        defer { flock(fd, LOCK_UN) }
        var info = stat()
        if fstat(fd, &info) != 0 { throw error(errno, path) }
        if info.st_mode & S_IFMT == S_IFDIR { throw DocumentError.unauthorized("Access to the path '\(path)' is denied.") }
        let length = Int64(info.st_size)
        if let limit, length > limit { throw tooLarge ?? DocumentError.io("File too large: '\(path)'") }
        var bytes = [UInt8](repeating: 0, count: Int(length))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, $0.count - offset) }
            if count < 0 { if errno == EINTR { continue }; throw error(errno, path) }
            if count == 0 { throw DocumentError.io("Unable to read beyond the end of the stream: '\(path)'") }
            offset += count
        }
        var extra: UInt8 = 0
        if read(fd, &extra, 1) > 0 { throw changed ?? DocumentError.io("File changed while reading: '\(path)'") }
        return bytes
    }

    /// `new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)`, write, `Flush(true)`.
    static func writeNew(_ path: String, _ bytes: [UInt8], flush: Bool = true) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 { throw error(errno, path) }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { throw error(errno, path) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if count < 0 { if errno == EINTR { continue }; throw error(errno, path) }
            offset += count
        }
        // FlushFileBuffers: F_FULLFSYNC reaches the medium; fall back to fsync where a file system lacks it.
        if flush && fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 { throw error(errno, path) }
    }

    /// `File.WriteAllBytes`: create or truncate, no locking.
    static func writeAll(_ path: String, _ bytes: [UInt8]) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd < 0 { throw error(errno, path) }
        defer { close(fd) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if count < 0 { if errno == EINTR { continue }; throw error(errno, path) }
            offset += count
        }
    }

    /// A file held open the way C# holds a `FileStream` with a sharing mode, until `close()` or deinit.
    /// `exclusive` is FileShare.None (nobody else may open it); otherwise FileShare.Read (others may read, nobody may replace it).
    final class Hold {
        private var fd: Int32
        let path: String
        init(_ path: String, exclusive: Bool, create: Bool = false) throws {
            self.path = path
            fd = open(path, (create ? O_CREAT : 0) | O_RDWR, 0o644)
            if fd < 0 && !create && errno == EACCES { fd = open(path, O_RDONLY) }
            if fd < 0 { throw NetFile.error(errno, path) }
            if flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
                let code = errno
                Darwin.close(fd); fd = -1
                throw NetFile.error(code, path)
            }
        }
        func close() { if fd >= 0 { flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 } }
        deinit { close() }
    }
}
