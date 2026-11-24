// Stub for the finance area: FinancialArithmetic, FinancialPlanning, IrrSolver, Earnings, Invoice, and their parsers.

final class InvoiceDueExpression: Expression {
    let date: Expression, days: Expression
    init(_ date: Expression, _ days: Expression) { self.date = date; self.days = days }
    var children: [Expression] { [date, days] }
}
final class LateFeeExpression: Expression {
    let principal: Expression, rate: Expression, duration: Expression
    init(_ principal: Expression, _ rate: Expression, _ duration: Expression) { self.principal = principal; self.rate = rate; self.duration = duration }
    var children: [Expression] { [principal, rate, duration] }
}
final class PlanningSentenceExpression: Expression {
    let name: String, arguments: [Expression]
    init(_ name: String, _ arguments: [Expression]) { self.name = name; self.arguments = arguments }
    var children: [Expression] { arguments }
}
final class FinancialPlanExpression: Expression {
    let kind: String, amount: Expression, rate: Expression, term: Expression, downPayment: Expression?
    var compoundingSpecified = false
    init(_ kind: String, _ amount: Expression, _ rate: Expression, _ term: Expression, _ downPayment: Expression? = nil) {
        self.kind = kind; self.amount = amount; self.rate = rate; self.term = term; self.downPayment = downPayment
    }
    var children: [Expression] { downPayment == nil ? [amount, rate, term] : [amount, rate, term, downPayment!] }
}
final class AmortizationYear {}
final class IrrEvidence {}
final class GrowthEvidence {}
final class EarningsValue: IdentityHashable {
    let amount: SheetValue, period: EarningsPeriod
    init(_ amount: SheetValue, _ period: EarningsPeriod) throws { self.amount = amount; self.period = period }
    var display: String { get throws { throw notPorted("earnings") } }
}
final class EarningsArithmetic {
    private(set) var assumption: String?
    init(_ math: ExactArithmetic, _ money: MoneyArithmetic, _ workdays: WorkdayArithmetic, _ context: EvaluationContext, _ reads: ContextReads, _ token: CancellationToken) {}
    func convert(_ value: SheetValue, _ period: EarningsPeriod) throws -> SheetValue { throw notPorted("earnings") }
    func currency(_ value: SheetValue, _ currency: String, _ money: MoneyArithmetic, _ attach: Bool = false) throws -> SheetValue { throw notPorted("earnings") }
    func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue { throw notPorted("earnings") }
    func unary(_ operation: String, _ value: SheetValue) throws -> SheetValue { throw notPorted("earnings") }
    func aggregate(_ values: [SheetValue], _ average: Bool) throws -> SheetValue { throw notPorted("earnings") }
    func round(_ kind: RoundingKind, _ value: SheetValue, _ precision: SheetValue) throws -> SheetValue { throw notPorted("earnings") }
}
final class FinancialArithmetic {
    init(_ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic) {}
    static func isPlanningFunction(_ name: String) -> Bool {
        ["cagr", "roi", "realreturn", "fire", "breakeven", "sln", "ddb", "syd"].contains(name.netLower)
    }
    static func isFunction(_ name: String) -> Bool { isPlanningFunction(name) || ["pmt", "fv", "pv", "npv", "irr"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        if isPlanningFunction(name) {
            let (minimum, maximum): (Int, Int)
            switch name.netLower { case "roi", "realreturn": (minimum, maximum) = (2, 2); case "fire": (minimum, maximum) = (1, 2); case "ddb": (minimum, maximum) = (4, 5); case "syd": (minimum, maximum) = (4, 4); default: (minimum, maximum) = (3, 3) }
            if count < minimum || count > maximum { throw CalcError.format("\(name) expects \(minimum)–\(maximum) arguments") }
            return
        }
        if name.equalsIgnoreCase("irr") { if count < 1 || count > 16 { throw CalcError.format("irr expects scalar cash flows or a list with an optional guess") }; return }
        let minimum = name.equalsIgnoreCase("npv") ? 2 : 3
        let maximum = minimum == 2 ? 16 : 5
        if count < minimum || count > maximum { throw CalcError.format("\(name) expects \(minimum)–\(maximum) arguments") }
    }
    static func invoiceDue(_ date: SheetValue, _ days: SheetValue) throws -> SheetValue { throw notPorted("invoices") }
    func lateFee(_ principal: SheetValue, _ rate: SheetValue, _ duration: SheetValue) throws -> (value: SheetValue, assumption: String) { throw notPorted("late fees") }
    func planningSentence(_ expression: PlanningSentenceExpression, _ inputs: [SheetValue]) throws -> (value: SheetValue, assumption: String) { throw notPorted("financial planning") }
    func plan(_ expression: FinancialPlanExpression, _ inputs: [SheetValue]) throws -> (value: SheetValue, assumption: String, schedule: [AmortizationYear]?) { throw notPorted("loans and savings plans") }
    func function(_ name: String, _ args: [SheetValue]) throws -> (value: SheetValue, assumption: String, irr: IrrEvidence?, growth: GrowthEvidence?) { throw notPorted("finance functions") }
}
extension ExpressionParser {
    func tryInvoiceSentence() throws -> Expression? { nil }
    func tryPlanningSentence() throws -> Expression? { nil }
    func tryFinancialSentence() throws -> Expression? { nil }
}
