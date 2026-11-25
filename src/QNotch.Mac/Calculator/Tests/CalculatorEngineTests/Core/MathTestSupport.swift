import XCTest
@testable import CalculatorEngine

/// A failed xUnit assertion inside a helper: stops the current test or theory row, as C#'s Assert does.
struct AssertionFailure: Error, CustomStringConvertible { let description: String }

/// Shared sheet helpers for the math-area test ports (matrices, statistics, complex, primes, constants, equations, calculus).
enum MathSheet {
    /// The last line's result, whatever it is (C# `SheetEvaluator.Evaluate(source)[^1]`).
    static func line(_ source: String, _ token: CancellationToken = .none, context: EvaluationContext? = nil) throws -> LineResult {
        try SheetEvaluator.evaluate(source, token, context: context).last!
    }
    /// The last line, which must not be an error (C# `Last` with `Assert.Null(result.Error)`).
    static func last(_ source: String, context: EvaluationContext? = nil) throws -> LineResult {
        let result = try line(source, context: context)
        if let error = result.error { throw AssertionFailure(description: "\(source): unexpected error \(error)") }
        return result
    }
    /// The last line's value (C# `Value`).
    static func value(_ source: String, context: EvaluationContext? = nil) throws -> SheetValue {
        guard let value = try last(source, context: context).value else { throw AssertionFailure(description: "\(source): no value") }
        return value
    }
    /// A displayed double, as C# `double.Parse(display)` reads it.
    static func double(_ text: String) throws -> Double {
        guard let value = Double(text) else { throw AssertionFailure(description: "not a number: \(text)") }
        return value
    }
    /// C#'s `(double)n / (double)d`.
    static func double(_ value: Rational) -> Double { value.numerator.toDouble() / value.denominator.toDouble() }
    /// `Assert.InRange`.
    static func inRange(_ actual: Double, _ low: Double, _ high: Double, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(actual >= low && actual <= high, "\(actual) not in [\(low), \(high)] \(message)", file: file, line: line)
    }
    /// C# `Rational.Parse("n/d")`-style fixture fraction.
    static func fraction(_ text: String) throws -> Rational {
        let parts = text.netSplit("/")
        return try Rational(BigInt(parts[0])!, parts.count == 1 ? .one : BigInt(parts[1])!)
    }
    /// A UTC midnight instant (C# `new DateTimeOffset(y, m, d, 0, 0, 0, TimeSpan.Zero)`).
    static func utc(_ year: Int, _ month: Int, _ day: Int) -> Instant {
        Instant(unixTicks: Int64(DateOnly(year, month, day)!.dayNumber) * Ticks.perDay - Ticks.unixEpoch)
    }
    /// `[[a,b],[c,d]]` from a cell generator, row by row (the C# tests build these with nested string.Join).
    static func matrixLiteral(_ rows: Int, _ columns: Int, _ cell: (Int, Int) -> String) -> String {
        var rowTexts: [String] = []
        for r in 0..<rows {
            var cells: [String] = []
            for c in 0..<columns { cells.append(cell(r, c)) }
            rowTexts.append("[" + cells.joined(separator: ",") + "]")
        }
        return "[" + rowTexts.joined(separator: ",") + "]"
    }
    /// `Assert.Throws<T>`: the error must be exactly this case.
    static func throwsError<T>(_ expected: CalcError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? CalcError, expected, file: file, line: line) }
    }
    /// `Assert.Throws<FormatException>`.
    static func throwsFormat<T>(file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertTrue(($0 as? CalcError)?.isFormat == true, "\($0)", file: file, line: line) }
    }
}
