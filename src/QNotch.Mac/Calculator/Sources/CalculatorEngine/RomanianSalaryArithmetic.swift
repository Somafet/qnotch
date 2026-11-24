import Foundation

// Port of RomanianSalaryArithmetic.cs.

struct RomanianPayrollEvidence: Equatable {
    let payrollMonth: DateOnly
    let monthlyGross: Rational, monthlyNet: Rational, monthlyBasicSalary: Rational, contributionBase: Rational, minimumRelief: Rational
    let baseDeduction: Rational, youthDeduction: Rational, childDeduction: Rational, appliedDeduction: Rational, taxableIncome: Rational
    let employerContribution: Rational, employerCost: Rational
    let dependants: Int, schoolChildren: Int, youthRelief: Bool, mainJob: Bool
}

/// Full-month normal-condition employee model, with a pinned reporting month and whole-leu settlement.
final class RomanianSalaryArithmetic {
    private let budget: ExecutionBudget, token: CancellationToken, money: MoneyArithmetic, context: EvaluationContext, reads: ContextReads
    private let math: ExactArithmetic
    private static let twelve = Rational(12)
    private static let maxMonthlyGross = PayrollArithmetic.maxAnnualGross / 12
    private var approximate = false
    private var outputCurrency: String?
    private var stamp: CurrencyRateStamp?

    init(_ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic, _ context: EvaluationContext, _ reads: ContextReads) {
        self.budget = budget; self.token = token; self.money = money; self.context = context; self.reads = reads
        math = ExactArithmetic(budget, token)
    }
    private func add(_ a: Rational, _ b: Rational) throws -> Rational { try math.add(ExactNumber(a), ExactNumber(b)).rational }
    private func subtract(_ a: Rational, _ b: Rational) throws -> Rational { try math.subtract(ExactNumber(a), ExactNumber(b)).rational }
    private func multiply(_ a: Rational, _ b: Rational) throws -> Rational { try math.multiply(ExactNumber(a), ExactNumber(b)).rational }
    private func divide(_ a: Rational, _ b: Rational) throws -> Rational { try math.divide(ExactNumber(a), ExactNumber(b)).rational }
    private static func maxZero(_ a: Rational) -> Rational { a.numerator.sign < 0 ? .zero : a }
    private func min(_ a: Rational, _ b: Rational) throws -> Rational {
        try budget.step(token); return a.numerator * b.denominator <= b.numerator * a.denominator ? a : b
    }
    /// Whole lei, half upward; a nonzero contribution never rounds to zero.
    private func round(_ value: Rational, contribution: Bool = false) throws -> Rational {
        try budget.step(token)
        if value.numerator.sign < 0 { throw CalcError.arithmetic("Negative Romanian payroll rounding input") }
        var (whole, remainder) = value.numerator.quotientAndRemainder(dividingBy: value.denominator)
        if remainder * BigInt(2) >= value.denominator { whole += .one }
        if contribution && whole.isZero && !value.numerator.isZero { whole = .one }
        return try Rational(whole)
    }
    private func output(_ value: Rational) throws -> SheetValue {
        var number = NumericValue(value); number.displayDecimalPlaces = 4; number.isApproximate = approximate
        guard let outputCurrency else { return .number(number) }
        return .money(try MoneyValue(number, outputCurrency, stamp))
    }
    private struct Rules {
        let month: DateOnly, minimum: Int, relief: Int, reliefCeiling: Int
        var version: String { month.month <= 6 ? "RO-employee-2026-H1-v1" : "RO-employee-2026-H2-v1" }
    }
    private func rules(_ expression: SalaryExpression) throws -> Rules {
        if expression.year != nil { throw CalcError.arithmetic("Romanian salary needs a payroll month; use for 2026-07-01 instead of a year alone") }
        var date = expression.payrollDate
        if date == nil { reads.dependencies.insert(.date); date = try context.requireToday() }
        let month = date!
        if month.year != 2026 { throw CalcError.arithmetic("Romanian salary rules available for January–December 2026 only") }
        let first = DateOnly(2026, month.month, 1)!
        return month.month <= 6 ? Rules(month: first, minimum: 4050, relief: 300, reliefCeiling: 4300) : Rules(month: first, minimum: 4325, relief: 200, reliefCeiling: 4600)
    }
    private func forward(_ gross: Int, _ rules: Rules, _ options: RomanianSalaryOptions) throws -> RomanianPayrollEvidence {
        try budget.step(token)
        let basic = options.basicSalary ?? gross
        let dependants = options.dependants ?? options.schoolChildren
        let relief = options.minimumRelief && options.mainJob && basic == rules.minimum && gross <= rules.reliefCeiling ? rules.relief : 0
        let contributionBase = Rational(gross - relief)
        let cas = try round(try multiply(contributionBase, Rational(1, 4)), contribution: true)
        let cass = try round(try multiply(contributionBase, Rational(1, 10)), contribution: true)
        var personal = Rational.zero, youth = Rational.zero, child = Rational.zero
        if options.mainJob {
            if gross <= rules.minimum + 2000 {
                let band = (Swift.max(0, gross - rules.minimum) + 49) / 50
                let initial = [40, 50, 60, 70, 90] // half percentage points, followed by one half-point decrease per band
                personal = try round(try multiply(Rational(rules.minimum), Rational(initial[Swift.min(dependants, 4)] - band, 200)))
                if options.youthRelief { youth = try round(try multiply(Rational(rules.minimum), Rational(15, 100))) }
            }
            child = Rational(options.schoolChildren * 100)
        }
        let available = RomanianSalaryArithmetic.maxZero(try subtract(try subtract(contributionBase, cas), cass))
        let applied = try min(available, try add(try add(personal, youth), child))
        let taxable = RomanianSalaryArithmetic.maxZero(try subtract(available, applied))
        let income = try round(try multiply(taxable, Rational(1, 10)))
        let net = try subtract(try subtract(try subtract(Rational(gross), cas), cass), income)
        let employer = try round(try multiply(contributionBase, Rational(9, 400)), contribution: true)
        return RomanianPayrollEvidence(payrollMonth: rules.month, monthlyGross: Rational(gross), monthlyNet: net, monthlyBasicSalary: Rational(basic),
                                       contributionBase: contributionBase, minimumRelief: Rational(relief), baseDeduction: personal, youthDeduction: youth,
                                       childDeduction: child, appliedDeduction: applied, taxableIncome: taxable, employerContribution: employer,
                                       employerCost: try add(Rational(gross), employer), dependants: dependants, schoolChildren: options.schoolChildren,
                                       youthRelief: options.youthRelief, mainJob: options.mainJob)
    }
    private func inverse(_ target: Int, _ rules: Rules, _ options: RomanianSalaryOptions) throws -> Int {
        // With a fixed deduction and relief, CAS quarter-leu and CASS tenth-leu rounding jumps
        // occur on disjoint integer gross steps. Net is nondecreasing within each interval.
        // Search EVERY interval in gross order: relief and deduction boundaries can lower net.
        let start = Swift.max(rules.minimum, options.basicSalary ?? 0)
        var edges: Set<Int> = [start, RomanianSalaryArithmetic.maxMonthlyGross + 1]
        func edge(_ value: Int) { if value > start && value <= RomanianSalaryArithmetic.maxMonthlyGross { edges.insert(value) } }
        edge(rules.minimum + 1)
        for band in 1...40 { edge(rules.minimum + 50 * band + 1) }
        edge(rules.reliefCeiling + 1)
        let points = edges.sorted()
        for index in 0..<(points.count - 1) {
            var low = points[index]; var high = points[index + 1] - 1
            let lowNet = try forward(low, rules, options).monthlyNet.numerator
            let highNet = try forward(high, rules, options).monthlyNet.numerator
            if BigInt(target) < lowNet || BigInt(target) > highNet { continue }
            while low < high {
                try budget.step(token); let middle = low + (high - low) / 2
                if try forward(middle, rules, options).monthlyNet.numerator >= BigInt(target) { high = middle } else { low = middle + 1 }
            }
            if try forward(low, rules, options).monthlyNet == Rational(target) { return low }
        }
        throw CalcError.arithmetic("No whole-leu gross within the supported full-month Romanian profile produces this exact net")
    }
    func evaluate(_ expression: SalaryExpression, _ value: SheetValue, _ origin: String) throws -> PayrollResult {
        let rules = try self.rules(expression); let options = expression.romanian ?? RomanianSalaryOptions()
        let dependants = options.dependants ?? options.schoolChildren
        if options.schoolChildren > dependants { throw CalcError.arithmetic("School children must be included in the total dependant count") }
        if !options.mainJob && (dependants > 0 || options.youthRelief) { throw CalcError.arithmetic("Personal deductions require the main-job profile") }
        if let basic = options.basicSalary, basic < rules.minimum || basic > RomanianSalaryArithmetic.maxMonthlyGross {
            throw CalcError.arithmetic("Full-month Romanian basic salary must be at least the dated minimum and within the gross bound")
        }
        let hadPeriod = value.kind == .earnings
        let period = hadPeriod ? try value.earnings.period : .month
        if period != .month && period != .year { throw CalcError.arithmetic("Annualize hourly/workday earnings explicitly before applying salary rules") }
        var amount = hadPeriod ? try value.earnings.amount : value
        if amount.kind == .money {
            let converted = try money.convert(try amount.money, "RON"); outputCurrency = "RON"; stamp = converted.rateStamp; amount = .number(converted.magnitude)
        }
        let number = try amount.number
        if !number.isRational || number.unit != nil || number.isPercentage { throw CalcError.arithmetic("Romanian salary requires a rational RON amount without units or percentages") }
        approximate = number.isApproximate
        let input = period == .year ? try divide(try number.scalar, RomanianSalaryArithmetic.twelve) : try number.scalar
        if !input.denominator.isOne || input.numerator.sign < 0 || input.numerator > BigInt(RomanianSalaryArithmetic.maxMonthlyGross) {
            throw CalcError.arithmetic("Romanian salary currently requires whole-leu monthly amounts within the annual gross bound")
        }
        let integer = input.numerator.intValue!
        let gross = expression.inverse ? try inverse(integer, rules, options) : integer
        if gross < rules.minimum || (options.basicSalary.map { $0 > gross } ?? false) {
            throw CalcError.arithmetic("Gross must cover the dated full-month minimum and the declared basic salary; partial-month/part-time profiles are unavailable")
        }
        let monthly = try forward(gross, rules, options)
        let returned = expression.employerCost ? monthly.employerCost : expression.inverse ? monthly.monthlyGross : monthly.monthlyNet
        var output = try self.output(period == .year ? try multiply(returned, RomanianSalaryArithmetic.twelve) : returned)
        if hadPeriod { output = .earnings(try EarningsValue(output, period)) }
        let cas = try round(try multiply(monthly.contributionBase, Rational(1, 4)), contribution: true)
        let cass = try round(try multiply(monthly.contributionBase, Rational(1, 10)), contribution: true)
        let income = try subtract(try subtract(try subtract(monthly.monthlyGross, cas), cass), monthly.monthlyNet)
        let twelve = RomanianSalaryArithmetic.twelve
        let deductions = [PayrollDeduction("CAS employee pension", try multiply(cas, twelve)), PayrollDeduction("CASS employee health", try multiply(cass, twelve)),
                          PayrollDeduction("Income tax", try multiply(income, twelve))]
        let monthText = String(rules.month.year).netPadLeft(4, "0") + "-" + String(rules.month.month).netPadLeft(2, "0")
        var detail = "Romanian salary \(expression.inverse ? "net to gross" : "gross to net"); RO from \(origin); \(rules.version); payroll month \(monthText); full month, normal working conditions, "
        detail += (options.mainJob ? "main job" : "other job") + "; basic salary \(monthly.monthlyBasicSalary) RON; total eligible dependants \(dependants), eligible school children claimed by this parent only \(options.schoolChildren); "
        detail += (options.youthRelief ? "youth relief eligibility asserted" : "no youth relief") + "; "
        detail += options.minimumRelief ? "minimum-wage relief assumes full-time eligibility and no disqualifying basic-pay reduction" : "minimum-wage relief disabled"
        detail += "; dated minimum \(rules.minimum) RON; monthly tax-free amount \(monthly.minimumRelief) RON; contribution base \(monthly.contributionBase) RON"
        detail += "; base/youth/child deductions \(monthly.baseDeduction)/\(monthly.youthDeduction)/\(monthly.childDeduction) RON; applied deduction \(monthly.appliedDeduction) RON; taxable \(monthly.taxableIncome) RON"
        detail += "; CAS \(cas) RON; CASS \(cass) RON; income tax \(income) RON; net \(monthly.monthlyNet) RON; employer CAM \(monthly.employerContribution) RON; employer cost \(monthly.employerCost) RON"
        detail += "; contributions/deduction fields rounded to whole lei, half upward; employer CAM allocated to this employee, not multiemployee aggregate settlement; no benefits, leave, special sectors, voluntary deductions or partial-month/part-time settlement; whole-leu monthly input domain"
        detail += period == .year ? "; annual output is twelve identical months under the selected month's rules, not a mixed-rule calendar-year settlement" : "; bare amounts default to monthly RON model units"
        detail += expression.inverse ? "; lowest whole-leu gross among all deduction/relief intervals, verified by exact forward net; other gross amounts may produce the same rounded net" : ""
        detail += approximate ? "; upstream input is approximate" : "; exact represented input"
        detail += money.provenance.map { "; " + $0 + "; generic exchange-rate conversion, not statutory BNR payroll conversion" } ?? ""
        if let target = expression.outputPeriod {
            let rate = hadPeriod ? output : .earnings(try EarningsValue(output, .month))
            let converter = EarningsArithmetic(math, money, WorkdayArithmetic(budget, token), context, reads, token)
            output = try converter.convert(rate, target); detail += "; " + (converter.assumption ?? "")
        }
        let firstHalf = rules.month.month <= 6
        let sources = ["https://static.anaf.ro/static/10/Anaf/legislatie/Cod_fiscal_norme_2023.htm",
                       "https://static.anaf.ro/static/10/Anaf/legislatie/OUG_89_2025.pdf",
                       "https://static.anaf.ro/static/10/Anaf/legislatie/" + (firstHalf ? "HG_1506_2024.pdf" : "HG_146_2026.pdf"),
                       "https://static.anaf.ro/static/10/Anaf/Declaratii_R/AplicatiiDec/" + (firstHalf ? "structura_D112_0126_300326.pdf" : "structura_D112_0726_070926.pdf")]
        detail += "; rule sources " + sources.joined(separator: "; ")
        var evidence = PayrollEvidence("RO", 2026, rules.version, try multiply(monthly.monthlyGross, twelve), try multiply(monthly.monthlyNet, twelve),
                                       try multiply(monthly.appliedDeduction, twelve), try multiply(monthly.taxableIncome, twelve), deductions, expression.inverse, approximate,
                                       "Whole-leu full-month Romanian employee model; annual fields project twelve identical selected-rule months")
        evidence.sources = sources; evidence.romanian = monthly
        return PayrollResult(output, detail, evidence)
    }
}
