import Foundation

extension FinancialArithmetic {
    func lateFee(_ principal: SheetValue, _ dailyRate: SheetValue, _ duration: SheetValue) throws -> FinancialResult {
        try setTemplate([principal]); let amount = try cash(principal)
        if amount.sign < 0 { throw CalcError.arithmetic("Late-fee principal must be nonnegative") }
        let rate = try plain(dailyRate, true)
        if rate.sign < 0 { throw CalcError.arithmetic("Daily late-fee rate must be nonnegative") }
        let time = try duration.number
        if time.unit?.dimension != TimeArithmetic.timeDimension || !time.isRational || time.isPercentage || time.isApproximate {
            throw CalcError.arithmetic("Late-fee duration requires an exact elapsed-time quantity")
        }
        let days = try divide(try time.exact.rational, Rational(86400))
        if days.sign < 0 { throw CalcError.arithmetic("Late-fee duration must be nonnegative") }
        if days.numerator > BigInt(3_660_000) * days.denominator { throw CalcError.arithmetic("Late-fee duration exceeds 3,660,000 days") }
        return FinancialResult(try output(try multiply(try multiply(amount, rate), days)),
            planningAssumption("Simple late fee = principal * explicit daily rate * elapsed days; fractional days prorated; day = 24 elapsed hours; no compounding, legal rate, grace period or statutory entitlement inferred"))
    }
    static func invoiceDue(_ issue: SheetValue, _ term: SheetValue) throws -> SheetValue {
        let number = try term.number
        if !number.isRational || number.unit != nil || number.isPercentage || number.isApproximate {
            throw CalcError.arithmetic("Net terms require an exact whole calendar-day count from 0 to 3,660,000")
        }
        let scalar = try number.scalar
        if !scalar.denominator.isOne || scalar.numerator < 0 || scalar.numerator > 3_660_000 {
            throw CalcError.arithmetic("Net terms require an exact whole calendar-day count from 0 to 3,660,000")
        }
        guard let due = try issue.date.addingDays(scalar.numerator.intValue!) else { throw CalcError.arithmetic("Invoice due date exceeds the Gregorian date range") }
        return .date(due)
    }
}
