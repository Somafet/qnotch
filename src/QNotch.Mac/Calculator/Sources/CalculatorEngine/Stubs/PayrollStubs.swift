// Stub for the payroll area: PayrollArithmetic (US, UK, RO, DE, HU), RomanianTaxArithmetic, SalaryExpressions.

final class SalaryExpression: Expression {
    let amount: Expression, inverse: Bool, outputPeriod: EarningsPeriod?, employerCost: Bool
    init(_ amount: Expression, _ inverse: Bool, outputPeriod: EarningsPeriod? = nil, employerCost: Bool = false) {
        self.amount = amount; self.inverse = inverse; self.outputPeriod = outputPeriod; self.employerCost = employerCost
    }
    var children: [Expression] { [amount] }
}
final class PayrollEvidence {}
final class RomanianTaxEvidence {}
final class PayrollArithmetic {
    init(_ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic, _ context: EvaluationContext, _ reads: ContextReads) {}
    func evaluate(_ expression: SalaryExpression, _ amount: SheetValue) throws -> (value: SheetValue, assumption: String, evidence: PayrollEvidence) { throw notPorted("payroll") }
}
final class RomanianTaxArithmetic {
    init(_ budget: ExecutionBudget, _ token: CancellationToken) {}
    static func isFunction(_ name: String) -> Bool {
        ["pfanetro", "pfataxro", "microtaxro", "dividendtaxro", "dividendcashro", "stocktaxro", "brokertaxro", "brokergainsro", "cryptotaxro", "investmentcassro"].contains(name.netLower)
    }
    static func validateArity(_ name: String, _ count: Int) throws {
        let (minimum, maximum): (Int, Int)
        switch name.netLower { case "pfanetro", "pfataxro": (minimum, maximum) = (3, 5); case "microtaxro", "brokertaxro": (minimum, maximum) = (3, 3); case "stocktaxro": (minimum, maximum) = (2, 3); default: (minimum, maximum) = (2, 2) }
        if count < minimum || count > maximum { throw CalcError.format("\(name) expects \(minimum)–\(maximum) arguments; tax year is explicit") }
    }
    func function(_ name: String, _ args: [SheetValue]) throws -> (value: SheetValue, assumption: String, evidence: RomanianTaxEvidence) { throw notPorted("Romanian tax") }
}
extension ExpressionParser {
    func trySalarySentence() throws -> Expression? { nil }
}
