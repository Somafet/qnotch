import Foundation

// Port of PayrollBreakdownText.cs.

enum PayrollBreakdownRowKind: Equatable { case base, deduction, credit, total, info }
struct PayrollBreakdownRow: Equatable {
    let label: String, amount: String, kind: PayrollBreakdownRowKind
    init(_ label: String, _ amount: String, _ kind: PayrollBreakdownRowKind) { self.label = label; self.amount = amount; self.kind = kind }
}
/// Footer names the answer's period only when it differs from the rows' period.
struct PayrollBreakdown: Equatable { let rows: [PayrollBreakdownRow], footer: String? }

/// Readable payroll breakdowns shared by the hover/F1 surfaces and the CLI explanation.
/// It formats evidence the evaluator already produced and never computes a separate answer.
enum PayrollBreakdownText {
    private static func f(_ forints: Int64) -> String { NetFormat.integer(forints, "N0").netReplace(",", " ") }
    private static func f(_ value: Rational) -> String {
        let (whole, remainder) = value.numerator.quotientAndRemainder(dividingBy: value.denominator)
        if remainder.isZero { return f(whole.int64Value!) }
        let rounded = (BigInt(2) * value.numerator + value.denominator) / (BigInt(2) * value.denominator) // nonnegative display amounts
        return "≈" + f(rounded.int64Value!)
    }
    private static func percent(_ part: Int64, _ whole: Int64, _ of: String) -> String {
        if whole == 0 { return "" }
        // 100m * part / whole: whole-forint amounts are far inside System.Decimal's range, so this cannot overflow.
        let share = try! (try! NetDecimal(100) * NetDecimal(part)) / NetDecimal(whole)
        return " (" + share.fixed(1) + "% of " + of + ")"
    }
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// One hover line: where the money goes, and the answer's period.
    static func summary(_ evidence: PayrollEvidence) -> String? {
        guard let hu = evidence.hungarian else { return nil }
        let per = hu.period == "year" ? "year" : "month"
        var parts = ["SZJA " + f(hu.personalIncomeTax), "TB járulék " + f(hu.socialSecurity)]
        if hu.profile == "átalányadó" { parts.append("szocho " + f(hu.socialContributionTax)) }
        if hu.familyContributionRelief > 0 { parts.append("relief +" + f(hu.familyContributionRelief)) }
        parts.append("net " + f(hu.net) + " HUF")
        let answer = hu.answerPeriod.map { "Answer is per " + $0 } ?? ""
        return parts.joined(separator: " · ") + " per " + per + (answer.isEmpty ? "" : "\n" + answer)
    }

    /// Hover-card rows: the base amount, what is taken or added back, then net for the evidence period.
    static func rows(_ evidence: PayrollEvidence) -> PayrollBreakdown? {
        guard let hu = evidence.hungarian else { return nil }
        let per = hu.period == "year" ? "year" : "month"
        let flat = hu.profile == "átalányadó"
        var rows = [PayrollBreakdownRow(flat ? "Revenue" : "Gross", f(hu.gross), .base)]
        if flat {
            rows.append(PayrollBreakdownRow("SZJA", "−" + f(hu.personalIncomeTax), .deduction))
            rows.append(PayrollBreakdownRow("TB járulék", "−" + f(hu.socialSecurity), .deduction))
            rows.append(PayrollBreakdownRow("szocho", "−" + f(hu.socialContributionTax), .deduction))
        } else {
            rows.append(PayrollBreakdownRow("TB járulék", "−" + f(hu.socialSecurity), .deduction))
            rows.append(PayrollBreakdownRow("SZJA", "−" + f(hu.personalIncomeTax), .deduction))
        }
        if hu.familyContributionRelief > 0 { rows.append(PayrollBreakdownRow("Family relief", "+" + f(hu.familyContributionRelief), .credit)) }
        rows.append(PayrollBreakdownRow("Net per " + per, f(hu.net) + " HUF", .total))
        if !flat { rows.append(PayrollBreakdownRow("Employer cost", f(hu.employerCost) + " HUF", .info)) }
        let footer = hu.answerPeriod.flatMap { $0 != per ? "Answer is per " + $0 : nil }
        return PayrollBreakdown(rows: rows, footer: footer)
    }

    /// F1 lines: totals, then (átalányadó) the twelve months.
    static func lines(_ evidence: PayrollEvidence) -> [String] {
        guard let hu = evidence.hungarian else { return [] }
        var lines: [String] = []
        if hu.profile == "átalányadó" {
            let paid = hu.personalIncomeTax + hu.socialSecurity + hu.socialContributionTax - hu.familyContributionRelief
            lines.append("Breakdown for 2026 (átalányadó, \(hu.status ?? ""), \(hu.costRatio.map { String($0) } ?? "")% cost ratio):")
            lines.append("  Revenue \(f(hu.gross)) HUF; income \(f(hu.income)) HUF; tax-free \(f(hu.taxFreeIncome)) HUF")
            lines.append("  SZJA \(f(hu.personalIncomeTax)) HUF; TB járulék \(f(hu.socialSecurity)) HUF; szocho \(f(hu.socialContributionTax)) HUF" +
                         (hu.familyContributionRelief > 0 ? "; family contribution relief −\(f(hu.familyContributionRelief)) HUF" : ""))
            // Net / 12 never fails: the denominator is a nonzero constant and the numerator a 64-bit amount.
            lines.append("  Taxes and contributions \(f(paid)) HUF\(percent(paid, hu.gross, "revenue")); net \(f(hu.net)) HUF a year, about \(f(try! Rational(BigInt(hu.net), BigInt(12)))) HUF a month")
            lines.append("Monthly (contributions are due monthly, paid quarterly; SZJA advance after each quarter):")
            for month in hu.months {
                lines.append("  \(monthNames[month.month - 1]): base \(f(month.contributionBase)), TB \(f(month.socialSecurity)), szocho \(f(month.socialContributionTax))" +
                             (month.month % 3 == 0 ? ", SZJA \(f(month.incomeTaxAdvance)) (Q\(month.month / 3))" : "") + ", left \(f(month.left))")
            }
            if hu.familyContributionRelief > 0 { lines.append("  Family contribution relief of \(f(hu.familyContributionRelief)) HUF is settled in the annual return") }
        } else {
            let deductions = hu.socialSecurity + hu.personalIncomeTax - hu.familyContributionRelief
            lines.append("Monthly breakdown (employee):")
            lines.append("  Gross \(f(hu.gross)) HUF; TB járulék \(f(hu.socialSecurity)) HUF; SZJA \(f(hu.personalIncomeTax)) HUF" +
                         (hu.familyContributionRelief > 0 ? "; family contribution relief +\(f(hu.familyContributionRelief)) HUF" : ""))
            lines.append("  Deductions \(f(deductions)) HUF\(percent(deductions, hu.gross, "gross")); net \(f(hu.net)) HUF a month, \(f(12 * hu.net)) HUF a year")
            lines.append("  Employer szocho \(f(hu.socialContributionTax)) HUF; employer cost \(f(hu.employerCost)) HUF a month")
        }
        return lines
    }
}
