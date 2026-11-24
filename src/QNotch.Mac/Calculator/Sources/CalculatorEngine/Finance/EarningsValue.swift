import Foundation

// `enum EarningsPeriod` (hour, day, month, year) lives in Core/ExpressionParser+Core.swift with the shared parser.

/// Amount per earnings period; calendar rates are not fixed elapsed-time quantities (C# EarningsValue record).
final class EarningsValue: Hashable {
    let amount: SheetValue
    let period: EarningsPeriod
    init(_ amount: SheetValue, _ period: EarningsPeriod) throws {
        let number = amount.kind == .money ? try amount.money.magnitude : try amount.number
        if number.unit != nil || number.isPercentage { throw CalcError.arithmetic("Earnings require an amount without physical units or percentages") }
        self.amount = amount; self.period = period
    }
    var display: String {
        get throws {
            let name: String
            switch period { case .hour: name = "hour"; case .day: name = "workday"; case .month: name = "month"; case .year: name = "year" }
            let text = try amount.display + "/" + name
            if text.netLength > 2048 { throw CalcError.arithmetic("Earnings output limit exceeded") }
            return text
        }
    }
    static func == (a: EarningsValue, b: EarningsValue) -> Bool { a.amount == b.amount && a.period == b.period }
    func hash(into hasher: inout Hasher) { hasher.combine(amount); hasher.combine(period) }
}
