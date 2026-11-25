import XCTest
@testable import CalculatorEngine

/// Shared helpers for the practical-helper tests (C# PracticalTestSupport.cs): evaluation with a fixed host snapshot and exact decimal literals as rationals.
enum Practical {
    /// 2026-10-31, 12:00 UTC.
    static let clock = EvaluationContext(today: DateOnly(2026, 10, 31)!, now: utc(2026, 10, 31, 12))
    /// `new DateTimeOffset(y, m, d, h, 0, 0, TimeSpan.Zero)` as an instant.
    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Instant {
        Instant(unixTicks: Int64(DateOnly(year, month, day)!.dayNumber) * Ticks.perDay + Int64(hour) * Ticks.perHour - Ticks.unixEpoch)
    }
    /// DateTimeOffset.UtcNow.
    static var now: Instant { Instant(unixTicks: Int64(Date().timeIntervalSince1970 * 10_000_000)) }
    static func last(_ source: String, _ context: EvaluationContext? = nil) throws -> LineResult { try SheetEvaluator.evaluate(source, context: context ?? clock).last! }
    static func value(_ source: String, _ context: EvaluationContext? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> SheetValue {
        let result = try last(source, context)
        guard result.error == nil, let value = result.value else {
            XCTFail(source.netReplace("\n", " / ") + " => " + (result.error ?? "no value"), file: file, line: line)
            throw CalcError.format("no value for " + source)
        }
        return value
    }
    static func show(_ source: String, _ context: EvaluationContext? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try value(source, context, file: file, line: line).display
    }
    static func fails(_ source: String, _ context: EvaluationContext? = nil) throws -> Bool { try last(source, context).error != nil }
    /// Exact rational from a decimal literal, independent of the evaluator's parser.
    static func r(_ decimalText: String) throws -> Rational { try Rational.parse(decimalText) }
    /// The canonical (SI) rational magnitude of a numeric result.
    static func canonical(_ value: SheetValue) throws -> Rational { try value.number.exact.rational }
    /// The magnitude in the result's own unit.
    static func inOwnUnit(_ value: SheetValue) throws -> Rational { try canonical(value) / value.number.unit!.factor }
}

/// C# `new Rational(BigInteger.Parse(a), BigInteger.Parse(b))` from "a/b" or "a".
func fraction(_ text: String) throws -> Rational {
    let parts = text.netSplit("/")
    return try Rational(BigInt(parts[0])!, parts.count == 1 ? .one : BigInt(parts[1])!)
}

/// C# `using static Calc.Core.Tests.Practical`: the helpers callable unqualified in the practical test classes.
protocol PracticalTesting {}
extension PracticalTesting {
    var clock: EvaluationContext { Practical.clock }
    func last(_ source: String, _ context: EvaluationContext? = nil) throws -> LineResult { try Practical.last(source, context) }
    func value(_ source: String, _ context: EvaluationContext? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> SheetValue {
        try Practical.value(source, context, file: file, line: line)
    }
    func show(_ source: String, _ context: EvaluationContext? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try Practical.show(source, context, file: file, line: line)
    }
    func fails(_ source: String, _ context: EvaluationContext? = nil) throws -> Bool { try Practical.fails(source, context) }
    func r(_ decimalText: String) throws -> Rational { try Practical.r(decimalText) }
    func canonical(_ value: SheetValue) throws -> Rational { try Practical.canonical(value) }
    func inOwnUnit(_ value: SheetValue) throws -> Rational { try Practical.inOwnUnit(value) }
}
