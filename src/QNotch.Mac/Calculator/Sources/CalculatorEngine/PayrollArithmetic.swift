import Foundation

// Port of PayrollArithmetic.cs: the US and UK annual models and the dispatch to the RO, DE and HU models.

struct PayrollDeduction: Equatable {
    let name: String, annualAmount: Rational
    init(_ name: String, _ annualAmount: Rational) { self.name = name; self.annualAmount = annualAmount }
}
/// What a salary line computed (C# record PayrollEvidence). Annual fields; country-specific detail in `romanian`/`german`/`hungarian`.
struct PayrollEvidence: Equatable {
    let country: String, taxYear: Int, ruleVersion: String
    let annualGross: Rational, annualNet: Rational, annualAllowance: Rational, annualTaxableIncome: Rational
    let deductions: [PayrollDeduction]
    let inverse: Bool, inputApproximate: Bool, basis: String
    var sources: [String] = []
    var romanian: RomanianPayrollEvidence?
    var german: GermanPayrollEvidence?
    var hungarian: HungarianPayrollEvidence?
    init(_ country: String, _ taxYear: Int, _ ruleVersion: String, _ annualGross: Rational, _ annualNet: Rational, _ annualAllowance: Rational,
         _ annualTaxableIncome: Rational, _ deductions: [PayrollDeduction], _ inverse: Bool, _ inputApproximate: Bool, _ basis: String) {
        self.country = country; self.taxYear = taxYear; self.ruleVersion = ruleVersion; self.annualGross = annualGross; self.annualNet = annualNet
        self.annualAllowance = annualAllowance; self.annualTaxableIncome = annualTaxableIncome; self.deductions = deductions
        self.inverse = inverse; self.inputApproximate = inputApproximate; self.basis = basis
    }
}
struct PayrollResult {
    let value: SheetValue, assumption: String, evidence: PayrollEvidence
    init(_ value: SheetValue, _ assumption: String, _ evidence: PayrollEvidence) { self.value = value; self.assumption = assumption; self.evidence = evidence }
}

extension EarningsPeriod {
    /// `period.ToString().ToLowerInvariant()`.
    var lowerName: String {
        switch self { case .hour: return "hour"; case .day: return "day"; case .month: return "month"; case .year: return "year" }
    }
}

/// Dated standard employee models. Exact annualized arithmetic, separate from payroll settlement.
final class PayrollArithmetic {
    static let supportedYear = 2026
    static let maxAnnualGross = 100_000_000
    private let budget: ExecutionBudget, token: CancellationToken, money: MoneyArithmetic, context: EvaluationContext, reads: ContextReads
    private let math: ExactArithmetic
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
    private func compare(_ a: Rational, _ b: Rational) throws -> Int {
        try budget.step(token); return BigInt.compare(a.numerator * b.denominator, b.numerator * a.denominator)
    }
    private func maxZero(_ value: Rational) -> Rational { value.numerator.sign < 0 ? .zero : value }
    private func min(_ a: Rational, _ b: Rational) throws -> Rational { try compare(a, b) <= 0 ? a : b }
    private func plain(_ value: SheetValue) throws -> Rational {
        let number = try value.number
        if !number.isRational || number.unit != nil || number.isPercentage { throw CalcError.arithmetic("Salary requires a rational amount without physical units or percentages") }
        approximate = approximate || number.isApproximate; return try number.scalar
    }
    private func output(_ value: Rational) throws -> SheetValue {
        var number = NumericValue(value); number.displayDecimalPlaces = 4; number.isApproximate = approximate
        guard let outputCurrency else { return .number(number) }
        return .money(try MoneyValue(number, outputCurrency, stamp))
    }
    private func country(_ explicitCountry: String?, _ amount: SheetValue) throws -> (country: String, origin: String) {
        if let explicitCountry { return (try PayrollArithmetic.normalizeCountry(explicitCountry), "explicit country") }
        if amount.kind == .money {
            let inferred: String?
            switch try amount.money.currency { case "USD": inferred = "US"; case "GBP": inferred = "UK"; case "RON": inferred = "RO"; case "EUR": inferred = "DE"; case "HUF": inferred = "HU"; default: inferred = nil }
            if let inferred { return (inferred, "input currency") }
        }
        reads.dependencies.insert(.payrollRegion)
        guard let region = context.payrollRegion, !region.utf16.allSatisfy(NetChar.isWhiteSpace) else {
            throw CalcError.arithmetic("Salary country unavailable; specify in US, UK, DE, RO or HU")
        }
        return (try PayrollArithmetic.normalizeCountry(region), "injected payroll region")
    }
    private static func normalizeCountry(_ value: String) throws -> String {
        if value.netLength != 2 || !value.utf16.allSatisfy(NetChar.isAsciiLetter) { throw CalcError.arithmetic("Salary country requires a two-letter region") }
        let upper = value.netUpper
        return upper == "GB" ? "UK" : upper
    }
    private func year(_ country: String, _ explicitYear: Int?) throws -> Int {
        if let explicitYear { return explicitYear }
        reads.dependencies.insert(.date)
        let today = try context.requireToday()
        return country == "UK" && today < DateOnly(today.year, 4, 6)! ? today.year - 1 : today.year
    }
    private struct Annual { let gross: Rational, net: Rational, allowance: Rational, taxable: Rational, deductions: [PayrollDeduction] }
    private func layerTax(_ taxable: Rational, _ bands: [(upper: Int, rate: Int)]) throws -> Rational {
        var result = Rational.zero; var lower = 0
        for (upper, rate) in bands {
            try budget.step(token); let width = maxZero(try subtract(try min(taxable, Rational(upper)), Rational(lower)))
            result = try add(result, try multiply(width, Rational(rate, 100))); lower = upper
        }
        return result
    }
    private func forward(_ country: String, _ gross: Rational) throws -> Annual {
        try budget.step(token)
        let allowance: Rational, taxable: Rational, deductions: [PayrollDeduction]
        if country == "US" {
            allowance = Rational(16100); taxable = maxZero(try subtract(gross, allowance))
            let income = try layerTax(taxable, [(12400, 10), (50400, 12), (105700, 22), (201775, 24), (256225, 32), (640600, 35), (PayrollArithmetic.maxAnnualGross, 37)])
            deductions = [PayrollDeduction("Federal income tax", income), PayrollDeduction("Social Security", try multiply(try min(gross, Rational(184500)), Rational(62, 1000))),
                          PayrollDeduction("Medicare", try multiply(gross, Rational(145, 10000))),
                          PayrollDeduction("Additional Medicare", try multiply(maxZero(try subtract(gross, Rational(200000))), Rational(9, 1000)))]
        } else {
            allowance = maxZero(try subtract(Rational(12570), try divide(maxZero(try subtract(gross, Rational(100000))), Rational(2))))
            taxable = maxZero(try subtract(gross, allowance))
            let income = try layerTax(taxable, [(37700, 20), (125140, 40), (PayrollArithmetic.maxAnnualGross, 45)])
            let basicNi = try multiply(try min(maxZero(try subtract(gross, Rational(12570))), Rational(37700)), Rational(8, 100))
            let upperNi = try multiply(maxZero(try subtract(gross, Rational(50270))), Rational(2, 100))
            deductions = [PayrollDeduction("Income tax", income), PayrollDeduction("Employee National Insurance", try add(basicNi, upperNi))]
        }
        var net = gross; for deduction in deductions { net = try subtract(net, deduction.annualAmount) }
        return Annual(gross: gross, net: net, allowance: allowance, taxable: taxable, deductions: deductions)
    }
    private func inverse(_ country: String, _ target: Rational) throws -> Rational {
        let edges = country == "US" ? [0, 16100, 28500, 66500, 121800, 184500, 200000, 217875, 272325, 656700, PayrollArithmetic.maxAnnualGross]
            : [0, 12570, 50270, 100000, 125140, PayrollArithmetic.maxAnnualGross]
        var low = try forward(country, .zero)
        for i in 1..<edges.count {
            let high = try forward(country, Rational(edges[i]))
            if try compare(target, high.net) <= 0 {
                let gross = try add(low.gross, try multiply(try subtract(target, low.net), try divide(try subtract(high.gross, low.gross), try subtract(high.net, low.net))))
                if try forward(country, gross).net != target { throw CalcError.arithmetic("Salary inverse verification failed within the precision bound") }
                return gross
            }
            low = high
        }
        throw CalcError.arithmetic("Target net exceeds the supported annual gross bound")
    }

    func evaluate(_ expression: SalaryExpression, _ value: SheetValue) throws -> PayrollResult {
        let period = value.kind == .earnings ? try value.earnings.period : .year
        let hadPeriod = value.kind == .earnings
        if period != .month && period != .year { throw CalcError.arithmetic("Annualize hourly/workday earnings explicitly before applying salary rules") }
        var amount = hadPeriod ? try value.earnings.amount : value
        let (country, origin) = try self.country(expression.country, amount)
        if country == "HU" { return try HungarianSalaryArithmetic(budget, token, money, context, reads).evaluate(expression, value, origin) }
        if expression.hungarian != nil { throw CalcError.arithmetic("Átalányadó, cost ratio, guaranteed minimum, pensioner, mothers' exemption and first-marriage options require Hungarian salary rules") }
        if country != "DE" && expression.german != nil { throw CalcError.arithmetic("Tax class, church tax, care-insurance children and health surcharge options require German salary rules") }
        if country == "RO" { return try RomanianSalaryArithmetic(budget, token, money, context, reads).evaluate(expression, value, origin) }
        if expression.romanian != nil || expression.employerCost { throw CalcError.arithmetic("Dependants, school children, youth/minimum relief and employer cost currently require Romanian salary rules") }
        if country == "DE" { return try GermanSalaryArithmetic(budget, token, money, context, reads).evaluate(expression, value, origin) }
        if country != "US" && country != "UK" { throw CalcError.arithmetic("Salary rules unavailable for " + country + "; supported US, UK, DE, RO and HU") }
        var pinnedYear = expression.year
        if let date = expression.payrollDate { pinnedYear = country == "UK" && date < DateOnly(date.year, 4, 6)! ? date.year - 1 : date.year }
        let year = try self.year(country, pinnedYear)
        if year != PayrollArithmetic.supportedYear { throw CalcError.arithmetic("Salary rules unavailable for \(country) tax year \(year); supported \(country == "UK" ? "2026/27" : "2026") only") }
        if amount.kind == .money {
            let native = country == "US" ? "USD" : "GBP"; let converted = try money.convert(try amount.money, native)
            outputCurrency = native; stamp = converted.rateStamp; amount = .number(converted.magnitude)
        }
        let input = try plain(amount); let periods = Rational(period == .month ? 12 : 1); let annualInput = try multiply(input, periods)
        if try annualInput.numerator.sign < 0 || compare(annualInput, Rational(PayrollArithmetic.maxAnnualGross)) > 0 {
            throw CalcError.arithmetic("Salary amount must be nonnegative and at most 100,000,000 annually")
        }
        let gross = expression.inverse ? try inverse(country, annualInput) : annualInput; let annual = try forward(country, gross)
        var output = try self.output(try divide(expression.inverse ? gross : annual.net, periods))
        if hadPeriod { output = .earnings(try EarningsValue(output, period)) }
        let rule = country == "US" ? "US-single-2026-v1" : "UK-EWNI-A-2026-27-v1"
        let assumptions = country == "US"
            ? "2026 calendar year; single employee under 65, not blind/dependent; standard deduction 16100 USD; federal income tax plus employee FICA; no state/local tax, credits, itemized/special deductions, benefits or pension contributions"
            : "2026/27 (6 April 2026–5 April 2027); England/Wales/Northern Ireland, standard personal allowance with continuous taper, Class 1 category A employee below pension age; annual NIC thresholds; no Scotland, student loans, pension, benefits or other reliefs"
        var detail = "Salary " + (expression.inverse ? "net to gross" : "gross to net") + "; " + country + " from " + origin + "; " + rule + "; " + assumptions
        detail += "; annualized continuous arithmetic before pay-period/statutory/cent settlement; " + (hadPeriod ? period.lowerName : "bare amount defaults to annual")
        detail += " input/output basis; source magnitude retained; display rounding is separate"
        detail += (approximate ? "; upstream amount is approximate" : "; exact represented amount") + (expression.inverse ? "; inverse verified by recomputing annual net" : "")
        detail += "; annual gross " + (try self.output(gross).display) + ", allowance/deduction " + (try self.output(annual.allowance).display) + ", taxable " + (try self.output(annual.taxable).display)
        detail += "; " + (try annual.deductions.map { $0.name + " annual " + (try self.output($0.annualAmount).display) }.joined(separator: "; ")) + "; annual net " + (try self.output(annual.net).display)
        detail += money.provenance.map { "; " + $0 } ?? ""
        if let target = expression.outputPeriod {
            let rate = hadPeriod ? output : .earnings(try EarningsValue(output, .year))
            let converter = EarningsArithmetic(math, money, WorkdayArithmetic(budget, token), context, reads, token)
            output = try converter.convert(rate, target); detail += "; " + (converter.assumption ?? "")
        }
        let sources = country == "US" ? ["https://www.irs.gov/irb/2025-45_IRB", "https://www.irs.gov/taxtopics/tc751"]
            : ["https://www.gov.uk/guidance/rates-and-thresholds-for-employers-2026-to-2027", "https://www.gov.uk/income-tax-rates"]
        detail += "; rule sources " + sources.joined(separator: "; ")
        var evidence = PayrollEvidence(country, year, rule, gross, annual.net, annual.allowance, annual.taxable, annual.deductions, expression.inverse, approximate,
                                       "Annualized continuous standard employee model; settlement/exclusions disclosed")
        evidence.sources = sources
        return PayrollResult(output, detail, evidence)
    }
}
