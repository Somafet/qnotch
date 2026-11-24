import XCTest
@testable import CalculatorEngine

/// Runs one xUnit [Theory] row per element and counts the rows, so Swift and C# case counts can be compared.
func theory<T>(_ rows: [T], file: StaticString = #filePath, line: UInt = #line, _ body: (T) throws -> Void) throws {
    for row in rows {
        do { try body(row) } catch { XCTFail("\(row): \(error)", file: file, line: line) }
        CaseCounter.record(file: "\(file)")
    }
}
/// The number of theory rows and fixture cases each test file ran, written at exit to
/// `.build/calculator-case-counts.json` for the C#/Swift comparison.
enum CaseCounter {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    static func record(file: String, count: Int = 1) {
        let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        lock.lock(); counts[name, default: 0] += count; lock.unlock()
    }
    static var snapshot: [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
}
