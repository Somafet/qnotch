import XCTest
@testable import CalculatorEngine

/// File helpers for the documents tests: the .NET File/Directory calls the C# tests make.
enum TestFiles {
    /// `Path.Combine(Path.GetTempPath(), folder, Guid.NewGuid().ToString("N"))`.
    static func temporary(_ folder: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(folder + "/" + UUID().netN)
    }
    static func path(_ parts: String...) -> String { parts.dropFirst().reduce(parts[0]) { ($0 as NSString).appendingPathComponent($1) } }
    /// `File.ReadAllText` (UTF-8).
    static func readText(_ path: String) throws -> String { String(decoding: try NetFile.readAll(path), as: UTF8.self) }
    /// `File.WriteAllText` (UTF-8 without a byte-order mark).
    static func writeText(_ path: String, _ text: String) throws { try NetFile.writeAll(path, Array(text.utf8)) }
    static func readBytes(_ path: String) throws -> [UInt8] { try NetFile.readAll(path) }
    static func writeBytes(_ path: String, _ bytes: [UInt8]) throws { try NetFile.writeAll(path, bytes) }
    static func exists(_ path: String) -> Bool { NetFile.fileExists(path) }
    static func directoryExists(_ path: String) -> Bool { NetFile.directoryExists(path) }
    /// `Directory.GetFiles(directory, pattern)` for patterns with `*` wildcards (case-insensitive, as on Windows).
    static func files(_ directory: String, _ pattern: String = "*") -> [String] {
        guard let names = try? NetFile.entries(directory) else { return [] }
        return names.filter { matches($0, pattern) }.map { (directory as NSString).appendingPathComponent($0) }
            .filter(NetFile.fileExists).sorted()
    }
    static func matches(_ name: String, _ pattern: String) -> Bool {
        let parts = pattern.lowercased().components(separatedBy: "*"); var rest = Substring(name.lowercased())
        guard rest.hasPrefix(parts[0]) else { return false }
        rest = rest.dropFirst(parts[0].count)
        for (i, part) in parts.enumerated().dropFirst() {
            if i == parts.count - 1 { return part.isEmpty || rest.hasSuffix(part) }
            guard let range = rest.range(of: part) else { return false }
            rest = rest[range.upperBound...]
        }
        return rest.isEmpty
    }
    static func delete(_ path: String) { try? NetFile.deleteTree(path) }
    /// `new FileStream(path, FileMode.Open, access, FileShare.Read)`: others may read; nobody may replace or delete it.
    static func holdShared(_ path: String) throws -> NetFile.Hold { try NetFile.Hold(path, exclusive: false) }
    /// `new FileStream(path, FileMode.Open, access, FileShare.None)`.
    static func holdExclusive(_ path: String) throws -> NetFile.Hold { try NetFile.Hold(path, exclusive: true) }
    /// `File.SetAttributes(path, FileAttributes.ReadOnly)` / `Normal`: POSIX write permission.
    static func setReadOnly(_ path: String, _ readOnly: Bool) { chmod(path, readOnly ? 0o444 : 0o644) }
}

/// The .NET exception type an xUnit `Assert.Throws<T>` (exact) or `Assert.ThrowsAny<T>` (T or a subclass) names.
enum Thrown {
    case io, anyIO, invalidData, invalidOperation, unsupportedVersion, argument, unauthorized, json, directoryNotFound, shareLink, importRejected
    func matches(_ error: Error) -> Bool {
        switch self {
        case .io: return (error as? DocumentError).map { if case .io = $0 { return true }; return false } ?? ((error as? CalcError).map { if case .io = $0 { return true }; return false } ?? false)
        case .anyIO: return error.isIOException
        case .invalidData: return error.isInvalidData
        case .invalidOperation: return error.isInvalidOperation
        case .unsupportedVersion: return error.isUnsupportedVersion
        case .argument: return error.isArgumentError
        case .unauthorized: return error.isUnauthorized
        case .json: return error.isJsonError
        case .directoryNotFound: return error.isDirectoryNotFound
        case .shareLink: return error.isShareLinkError
        case .importRejected: return error.isImportRejected
        }
    }
}

@discardableResult
func assertThrows<T>(_ kind: Thrown, _ expression: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Error? {
    do {
        _ = try expression()
        XCTFail("Expected \(kind) but nothing was thrown. \(message)", file: file, line: line)
        return nil
    } catch {
        XCTAssertTrue(kind.matches(error), "Expected \(kind), got \(error) (\(type(of: error))). \(message)", file: file, line: line)
        return error
    }
}

extension Array where Element == UInt8 {
    var utf8Text: String { String(decoding: self, as: UTF8.self) }
}
