import XCTest
@testable import CalculatorEngine

/// A failed C# `Assert` inside a helper: thrown so the current theory row or test stops, as xUnit's assertion would.
struct PayrollAssertion: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Helpers shared by the payroll test ports (the C# classes each declare the same private helpers).
enum PayrollTest {
    static let today = DateOnly(2026, 10, 31)!
    static func context(_ today: DateOnly = PayrollTest.today, workday: String = "DE", region: String? = nil) -> EvaluationContext {
        var context = EvaluationContext(today: today, workdayRegion: workday); context.payrollRegion = region; return context
    }
    /// `SheetEvaluator.Evaluate(source, context: context)[^1]`.
    static func line(_ source: String, _ context: EvaluationContext?) throws -> LineResult {
        try SheetEvaluator.evaluate(source, context: context).last!
    }
    /// The last line, asserting it has no error (C# `Last`).
    static func last(_ source: String, _ context: EvaluationContext?) throws -> LineResult {
        let result = try line(source, context)
        if let error = result.error { throw PayrollAssertion("\(source): unexpected error \(error)") }
        return result
    }
    /// `Assert.Single(items, predicate)`.
    static func single<T>(_ items: [T], _ predicate: (T) throws -> Bool) throws -> T {
        let matches = try items.filter(predicate)
        if matches.count != 1 { throw PayrollAssertion("Expected a single match, found \(matches.count)") }
        return matches[0]
    }
    static func payrollStep(_ result: LineResult) throws -> CalculationStep { try single(result.explanation) { $0.payroll != nil } }
    static func payroll(_ result: LineResult) throws -> PayrollEvidence { try payrollStep(result).payroll! }
    static func romanianTax(_ result: LineResult) throws -> RomanianTaxEvidence { try single(result.explanation) { $0.romanianTax != nil }.romanianTax! }
    /// "n" or "n/d" as an exact rational (C# `new Rational(BigInteger.Parse(n), BigInteger.Parse(d))`).
    static func rational(_ text: String) throws -> Rational {
        let parts = text.netSplit("/")
        guard let numerator = BigInt(parts[0]), let denominator = parts.count == 1 ? BigInt.one : BigInt(parts[1]) else { throw PayrollAssertion("Bad rational \(text)") }
        return try Rational(numerator, denominator)
    }
    /// The numeric amount of a result, through earnings and money.
    static func amount(_ result: LineResult) throws -> Rational {
        guard var value = result.value else { throw PayrollAssertion("No value") }
        if value.kind == .earnings { value = try value.earnings.amount }
        return value.kind == .money ? try value.money.magnitude.scalar : try value.scalar
    }
    static func fixture(_ name: String) throws -> JSONNode { try JSONNode.parse(try Fixtures.data(name)) }
    static func snapshot(_ provider: String, _ asOf: DateOnly, _ retrievedAt: Instant, _ rates: [(String, Rational)]) throws -> CurrencyRateSnapshot {
        try CurrencyRateSnapshot(provider: provider, baseCurrency: "EUR", asOf: asOf, retrievedAt: retrievedAt, rates: rates)
    }
    /// C# record equality of two cached line results: same line, value, error and explanation steps.
    static func same(_ a: LineResult, _ b: LineResult) -> Bool {
        a === b || (a.line == b.line && a.value == b.value && a.error == b.error && a.explanation == b.explanation)
    }
    /// The text block of `spec/payroll.md` under `heading` (first ```text fence), split into lines.
    static func specBlock(_ heading: String) throws -> [String] {
        let spec = try Fixtures.text("spec/payroll.md").netReplace("\r\n", "\n")
        let start = spec.netIndexOf(heading); if start < 0 { throw PayrollAssertion("Missing \(heading)") }
        let section = spec.netSubstring(start)
        let open = section.netIndexOf("```text\n") + 8, close = section.netIndexOf("\n```\n")
        return section.netSlice(open, close).netSplit("\n")
    }
}
