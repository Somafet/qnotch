import Foundation

// Port of GermanSalaryArithmetic.cs. Money amounts are NetDecimal (System.Decimal) exactly where C# uses decimal.

struct GermanSalaryOptions: Equatable {
    var taxClass = 1
    var children = 0
    var childAllowances = NetDecimal.zero
    var healthSurchargePercent: NetDecimal? = nil
    var saxony = false
    var childlessSurcharge = true
    var churchTaxPercent = 0
}

struct GermanPayrollEvidence: Equatable {
    let period: String, taxClass: Int
    let gross: NetDecimal, net: NetDecimal, wageTax: NetDecimal, solidarity: NetDecimal, churchTaxBase: NetDecimal, churchTax: NetDecimal
    let pension: NetDecimal, unemployment: NetDecimal, health: NetDecimal, care: NetDecimal
    let annualTaxableIncome: NetDecimal, annualProvisionAllowance: NetDecimal, annualTableAllowances: NetDecimal
    let children: Int, childAllowances: NetDecimal, healthSurchargePercent: NetDecimal, saxony: Bool, childlessSurcharge: Bool, churchTaxPercent: Int
}

/// Germany 2026 current-wage employee model: official BMF wage-tax program plus statutory employee
/// social-insurance shares. Monthly input runs one monthly payroll period (LZZ 2); annual input runs the
/// annual table (LZZ 1). Whole-cent domain above the Übergangsbereich.
final class GermanSalaryArithmetic {
    static let ruleVersion = "DE-employee-2026-v1"
    static let defaultHealthSurcharge = NetDecimal(29, scale: 1)
    private static let healthCeiling = NetDecimal(69750), pensionCeiling = NetDecimal(101400)
    private static let minimumMonthlyCents: Int64 = 200001, minimumAnnualCents: Int64 = 2400001
    private static let maximumAnnualCents = Int64(PayrollArithmetic.maxAnnualGross) * 100, maximumMonthlyCents = maximumAnnualCents / 12
    // Bound on how far net can fall after a lower gross (cent rounding of tax/contributions); the oracle's
    // exhaustive windows observed at most 27 (monthly) and 108 (annual) cents.
    static let monthlyDipBoundCents: Int64 = 200, annualDipBoundCents: Int64 = 2000
    static let sources = [
        "https://www.bmf-steuerrechner.de/javax.faces.resource/daten/xmls/Lohnsteuer2026.xml.xhtml",
        "https://www.ihk-muenchen.de/ihk/documents/Recht-Steuern/Steuerrecht/Einkommensteuer/2025-11-12-PAP-2026-anlage-1.pdf",
        "https://www.gesetze-im-internet.de/svbezgrv_2026/__4.html",
        "https://www.gesetze-im-internet.de/sgb_5/__241.html",
        "https://www.bundesanzeiger.de/pub/publication/oUJYVk8GYRXybnb9Y4h/content/oUJYVk8GYRXybnb9Y4h/BAnz%20AT%2010.11.2025%20B7.pdf"]
    private let budget: ExecutionBudget, token: CancellationToken, money: MoneyArithmetic, context: EvaluationContext, reads: ContextReads
    private let math: ExactArithmetic
    private var approximate = false
    private var outputCurrency: String?
    private var stamp: CurrencyRateStamp?

    init(_ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic, _ context: EvaluationContext, _ reads: ContextReads) {
        self.budget = budget; self.token = token; self.money = money; self.context = context; self.reads = reads
        math = ExactArithmetic(budget, token)
    }

    struct Monthly {
        let gross: Int64, net: Int64, tax: GermanWageTaxResult, churchTax: Int64, pension: Int64, unemployment: Int64, health: Int64, care: Int64
    }

    private static func halfUpCents(_ euros: NetDecimal) throws -> Int64 { try (try euros * NetDecimal(100)).rounded(0, awayFromZero: true).int64 }
    private static func d(_ mantissa: Int64, _ scale: Int = 0) -> NetDecimal { NetDecimal(mantissa, scale: scale) }
    static func calculate(_ grossCents: Int64, _ annual: Bool, _ options: GermanSalaryOptions) throws -> Monthly {
        let surcharge = options.healthSurchargePercent ?? defaultHealthSurcharge
        let childless = options.children == 0 && options.childlessSurcharge
        let discounts = Swift.max(0, Swift.min(options.children, 5) - 1)
        let tax = try GermanWageTax2026.calculate(GermanWageTaxInput(period: annual ? 1 : 2, wageCents: NetDecimal(grossCents), taxClass: options.taxClass,
            childAllowances: options.childAllowances, healthSurchargePercent: surcharge, saxony: options.saxony, childlessSurcharge: childless,
            careDiscounts: discounts, church: options.churchTaxPercent > 0))
        let church = options.churchTaxPercent > 0 ? try (try (try tax.churchBaseCents * NetDecimal(options.churchTaxPercent)) / d(100)).truncated.int64 : 0
        let gross = try NetDecimal(grossCents) / d(100); let divisor = annual ? d(1) : d(12)
        let healthBase = NetDecimal.minimum(gross, try healthCeiling / divisor), pensionBase = NetDecimal.minimum(gross, try pensionCeiling / divisor)
        let careRate = try (try (options.saxony ? d(23, 3) : d(18, 3)) + (childless ? d(6, 3) : d(0))) - (try d(25, 4) * NetDecimal(discounts))
        let pension = try halfUpCents(try pensionBase * d(93, 3)), unemployment = try halfUpCents(try pensionBase * d(13, 3))
        let health = try halfUpCents(try healthBase * (try d(73, 3) + (try surcharge / d(200)))), care = try halfUpCents(try healthBase * careRate)
        let net = grossCents - (try tax.wageTaxCents.int64) - (try tax.solidarityCents.int64) - church - pension - unemployment - health - care
        return Monthly(gross: grossCents, net: net, tax: tax, churchTax: church, pension: pension, unemployment: unemployment, health: health, care: care)
    }
    private func forward(_ gross: Int64, _ annual: Bool, _ options: GermanSalaryOptions) throws -> Monthly {
        try budget.step(token); return try GermanSalaryArithmetic.calculate(gross, annual, options)
    }
    private func inverse(_ target: Int64, _ annual: Bool, _ options: GermanSalaryOptions) throws -> Int64 {
        let low = annual ? GermanSalaryArithmetic.minimumAnnualCents : GermanSalaryArithmetic.minimumMonthlyCents
        let high = annual ? GermanSalaryArithmetic.maximumAnnualCents : GermanSalaryArithmetic.maximumMonthlyCents
        let dip = annual ? GermanSalaryArithmetic.annualDipBoundCents : GermanSalaryArithmetic.monthlyDipBoundCents
        if try forward(high, annual, options).net < target { throw CalcError.arithmetic("Target net exceeds the supported German gross bound") }
        let crossing: Int64
        if try forward(low, annual, options).net >= target { crossing = low }
        else {
            var below = low, above = high // Net(below) < target <= Net(above)
            while above - below > 1 {
                let middle = below + (above - below) / 2
                if try forward(middle, annual, options).net >= target { above = middle } else { below = middle }
            }
            crossing = above
        }
        // No gross below a point whose net is more than the dip bound under the target can reach the target.
        var lowest: Int64? = nil
        var gross = crossing - 1
        while gross >= low {
            let net = try forward(gross, annual, options).net
            if net == target { lowest = gross }
            if net < target - dip { break }
            gross -= 1
        }
        if let lowest { return lowest }
        gross = crossing
        while gross <= high {
            let net = try forward(gross, annual, options).net
            if net == target { return gross }
            if net > target + dip { break }
            gross += 1
        }
        throw CalcError.arithmetic("No whole-cent gross within the supported German profile produces this exact net")
    }
    private func output(_ euros: NetDecimal) throws -> SheetValue {
        var number = NumericValue(try Rational.parse(euros.description)); number.displayDecimalPlaces = 4; number.isApproximate = approximate
        guard let outputCurrency else { return .number(number) }
        return .money(try MoneyValue(number, outputCurrency, stamp))
    }
    /// `cents / 100m`.
    private static func euros(_ cents: Int64) throws -> NetDecimal { try NetDecimal(cents) / d(100) }

    func evaluate(_ expression: SalaryExpression, _ value: SheetValue, _ origin: String) throws -> PayrollResult {
        let options = expression.german ?? GermanSalaryOptions()
        if options.taxClass < 1 || options.taxClass > 6 { throw CalcError.arithmetic("German tax class must be 1 through 6") }
        if options.childAllowances.sign > 0 && options.taxClass > 4 { throw CalcError.arithmetic("Child allowances apply only in German tax classes 1 through 4") }
        var year = expression.year ?? expression.payrollDate?.year
        if year == nil { reads.dependencies.insert(.date); year = try context.requireToday().year }
        if year != 2026 { throw CalcError.arithmetic("German salary rules unavailable for \(year!); supported 2026 only") }
        let hadPeriod = value.kind == .earnings
        let period = hadPeriod ? try value.earnings.period : .year
        if period != .month && period != .year { throw CalcError.arithmetic("Annualize hourly/workday earnings explicitly before applying salary rules") }
        let annual = period == .year
        var amount = hadPeriod ? try value.earnings.amount : value
        if amount.kind == .money {
            let converted = try money.convert(try amount.money, "EUR"); outputCurrency = "EUR"; stamp = converted.rateStamp; amount = .number(converted.magnitude)
        }
        let number = try amount.number
        if !number.isRational || number.unit != nil || number.isPercentage { throw CalcError.arithmetic("German salary requires a rational EUR amount without units or percentages") }
        approximate = number.isApproximate
        let scaled = try math.multiply(ExactNumber(try number.scalar), ExactNumber(Rational(100))).rational
        if !scaled.denominator.isOne || scaled.numerator.sign < 0 { throw CalcError.arithmetic("German salary requires a nonnegative whole-cent amount") }
        let minimum = annual ? GermanSalaryArithmetic.minimumAnnualCents : GermanSalaryArithmetic.minimumMonthlyCents
        let maximum = annual ? GermanSalaryArithmetic.maximumAnnualCents : GermanSalaryArithmetic.maximumMonthlyCents
        if scaled.numerator > BigInt(maximum) { throw CalcError.arithmetic("Salary amount must be at most 100,000,000 EUR annually") }
        let input = scaled.numerator.int64Value!
        let gross = expression.inverse ? try inverse(input, annual, options) : input
        if gross < minimum {
            throw CalcError.arithmetic(annual ? "German model requires annual gross above 24,000 EUR; Minijob/Übergangsbereich contributions are unavailable"
                : "German model requires monthly gross above 2,000 EUR; Minijob/Übergangsbereich contributions are unavailable")
        }
        let result = try forward(gross, annual, options)
        let returned = expression.inverse ? result.gross : result.net
        var output = try self.output(try GermanSalaryArithmetic.euros(returned))
        if hadPeriod { output = .earnings(try EarningsValue(output, period)) }
        let surcharge = options.healthSurchargePercent ?? GermanSalaryArithmetic.defaultHealthSurcharge
        let childless = options.children == 0 && options.childlessSurcharge
        func e(_ cents: Int64) throws -> String { try GermanSalaryArithmetic.euros(cents).fixed(2) + " EUR" }
        let label = annual ? "annual" : "monthly"
        var detail = "German salary \(expression.inverse ? "net to gross" : "gross to net"); DE from \(origin); \(GermanSalaryArithmetic.ruleVersion); 2026 \(label) payroll period (PAP LZZ \(annual ? 1 : 2)); tax class \(options.taxClass)"
        detail += "; child allowances \(options.childAllowances.description); children for care insurance \(options.children)"
        detail += childless ? "; childless care surcharge (age 23 or older assumed)"
            : options.children > 0 ? "; parent care rate" + (options.children > 1 ? " with \(Swift.min(options.children, 5) - 1) child discount(s), children under 25 assumed" : "")
            : "; no childless care surcharge"
        detail += "; statutory health insurance with \(surcharge.description)% Zusatzbeitrag\(options.healthSurchargePercent == nil ? " (2026 average)" : "")"
        detail += (options.saxony ? "; Saxony care insurance split" : "") + (options.churchTaxPercent > 0 ? "; church tax \(options.churchTaxPercent)%" : "; no church tax")
        detail += "; gross \(try e(result.gross)); wage tax \(try e(try result.tax.wageTaxCents.int64)); solidarity surcharge \(try e(try result.tax.solidarityCents.int64))"
        detail += options.churchTaxPercent > 0 ? "; church tax \(try e(result.churchTax)) on base \(try e(try result.tax.churchBaseCents.int64))" : ""
        detail += "; pension \(try e(result.pension)); unemployment \(try e(result.unemployment)); health \(try e(result.health)); care \(try e(result.care)); net \(try e(result.net))"
        detail += "; annual taxable income \(result.tax.annualTaxableIncome.fixed(2)) EUR after Vorsorgepauschale \(result.tax.annualProvisionAllowance.description) EUR"
        detail += "; BMF 2026 machine wage-tax program, current wage only; employee contribution shares rounded half up to cents per branch; church tax truncated to cents; no Minijob/Übergangsbereich, private insurance, Versorgungsbezüge, other payments, allowances on the tax card, factor method, U1/U2/insolvency levies or employer cost"
        detail += annual ? "; annual table and ceilings, not twelve settled monthly runs" : "; one monthly payroll period, not annual reconciliation"
        detail += expression.inverse ? "; lowest whole-cent gross producing the exact net, verified by recomputing; other gross amounts may produce the same net" : ""
        detail += approximate ? "; upstream amount is approximate" : "; exact represented amount"
        detail += money.provenance.map { "; " + $0 } ?? ""
        if let target = expression.outputPeriod {
            let rate = hadPeriod ? output : .earnings(try EarningsValue(output, .year))
            let converter = EarningsArithmetic(math, money, WorkdayArithmetic(budget, token), context, reads, token)
            output = try converter.convert(rate, target); detail += "; " + (converter.assumption ?? "")
        }
        detail += "; rule sources " + GermanSalaryArithmetic.sources.joined(separator: "; ")
        let periods = NetDecimal(annual ? 1 : 12)
        func a(_ euros: NetDecimal) throws -> Rational { try Rational.parse((try euros * periods).description) }
        func c(_ cents: Int64) throws -> Rational { try a(try GermanSalaryArithmetic.euros(cents)) }
        let tax = result.tax
        let deductions = [PayrollDeduction("Wage tax", try c(try tax.wageTaxCents.int64)), PayrollDeduction("Solidarity surcharge", try c(try tax.solidarityCents.int64)),
                          PayrollDeduction("Church tax", try c(result.churchTax)), PayrollDeduction("Pension insurance", try c(result.pension)),
                          PayrollDeduction("Unemployment insurance", try c(result.unemployment)), PayrollDeduction("Health insurance", try c(result.health)),
                          PayrollDeduction("Care insurance", try c(result.care))]
        let hundred = GermanSalaryArithmetic.d(100)
        let german = GermanPayrollEvidence(period: label, taxClass: options.taxClass, gross: try GermanSalaryArithmetic.euros(result.gross), net: try GermanSalaryArithmetic.euros(result.net),
            wageTax: try tax.wageTaxCents / hundred, solidarity: try tax.solidarityCents / hundred, churchTaxBase: try tax.churchBaseCents / hundred,
            churchTax: try GermanSalaryArithmetic.euros(result.churchTax), pension: try GermanSalaryArithmetic.euros(result.pension),
            unemployment: try GermanSalaryArithmetic.euros(result.unemployment), health: try GermanSalaryArithmetic.euros(result.health), care: try GermanSalaryArithmetic.euros(result.care),
            annualTaxableIncome: tax.annualTaxableIncome, annualProvisionAllowance: tax.annualProvisionAllowance, annualTableAllowances: tax.annualTableAllowances,
            children: options.children, childAllowances: options.childAllowances, healthSurchargePercent: surcharge, saxony: options.saxony,
            childlessSurcharge: childless, churchTaxPercent: options.churchTaxPercent)
        var evidence = PayrollEvidence("DE", 2026, GermanSalaryArithmetic.ruleVersion, try c(result.gross), try c(result.net),
                                       try Rational.parse((try tax.annualTableAllowances + tax.annualProvisionAllowance).description),
                                       try Rational.parse(tax.annualTaxableIncome.description), deductions, expression.inverse, approximate,
                                       annual ? "German 2026 annual wage-tax table and employee social insurance" : "German 2026 monthly payroll period; annual fields project twelve identical months")
        evidence.sources = GermanSalaryArithmetic.sources; evidence.german = german
        return PayrollResult(output, detail, evidence)
    }
}
