import Foundation

/// Calculator answers for Search (Windows CalculatorEngine.Quick and CalculatorSearch.LooksLikeCalculation).
/// Evaluation is safe from any thread; the session serializes its own work.
public final class CalculatorQuick: @unchecked Sendable {
    private let session = SheetEvaluationSession()
    public init() {}

    /// The answer and copy text for one expression, or nil unless it is a real calculation whose answer says something the query did not.
    public func answer(_ expression: String, environment: CalculatorEnvironment = CalculatorEnvironment(), format: CalculatorFormat = CalculatorFormat(),
                       functions: CalculatorFunctions? = nil, rates: CalculatorRates? = nil, cancel: CalculatorCancellation? = nil) -> (answer: String, copy: String)? {
        guard let results = try? session.evaluateWithFunctions(expression, functions?.library ?? .empty, [], cancel?.token ?? .none, context: environment.context(rates: rates?.book)).results,
              results.count == 1, let result = results.first, result.error == nil, !result.isDeclaration, let value = result.value else { return nil }
        // Uuid and dice lines have no stable answer outside a sheet, and pictures do not fit a result row.
        if [.plot, .chart, .table].contains(value.kind) || result.pending != nil { return nil }
        guard let line = try? CalculatorPresentation.present(result, value, format.resultFormat) else { return nil }
        return line.answer.equalsIgnoreCase(expression.netTrim) ? nil : line
    }

    public static let maxQuery = 160

    /// A cheap check that keeps ordinary searches from loading the engine or taking the first result. The query must start like a
    /// calculation (a number, sign, bracket, currency symbol or function call) and hold an operator, a conversion or a call.
    public static func looksLikeCalculation(_ query: String) -> Bool {
        let u = query.units
        if u.count < 2 || u.count > maxQuery || !u.contains(where: NetChar.isAsciiDigit) { return false }
        if query.contains("\\") || query.contains("://") || query.contains("@") { return false }
        if !startsLikeCalculation(u) { return false }
        if u.contains(where: { "+*/^%×÷-".utf16.contains($0) }) { return true }
        let lower = query.netLower
        if lower.contains(" in ") || lower.contains(" to ") || lower.contains(" as ") { return true }
        for i in 1..<u.count where u[i] == 0x28 && NetChar.isLetter(u[i - 1]) { return true }
        return false
    }
    private static func startsLikeCalculation(_ u: [UInt16]) -> Bool {
        let first = u[0]
        if NetChar.isAsciiDigit(first) || "(-+.$€£¥√".utf16.contains(first) { return true }
        var i = 0
        while i < u.count && NetChar.isAsciiLetter(u[i]) { i += 1 }
        return i > 0 && i < u.count && u[i] == 0x28
    }
}
