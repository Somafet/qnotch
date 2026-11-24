import Foundation

// Port of HungarianSalaryArithmetic.cs.

struct HungarianSalaryOptions: Equatable {
    var flatRate = false
    var costRatio: Int? = nil
    var guaranteedMinimum = false
    var pensioner = false
    var mothersExemption = false
    var firstMarriage = false
}

/// Hungarian 2026 amounts in whole forints. Employee fields are one month; flat-rate (átalányadó) fields are the tax year.
struct HungarianPayrollEvidence: Equatable {
    let profile: String, period: String, gross: Int64, net: Int64, income: Rational, taxFreeIncome: Int64
    let taxableIncome: Rational, allowances: Rational, familyAllowanceUsed: Rational, taxBase: Rational, personalIncomeTax: Int64, socialSecurityBase: Rational
    let socialSecurity: Int64, familyContributionRelief: Int64, socialContributionTaxBase: Rational, socialContributionTax: Int64, employerCost: Int64
    let children: Int, dependants: Int, youthExemption: Bool, mothersExemption: Bool, firstMarriage: Bool, costRatio: Int?, status: String?
    /// Átalányadó only: the twelve monthly liabilities. Family contribution relief is settled annually and excluded.
    var months: [HungarianPayrollMonth] = []
    /// "month" or "year" for the line's answer; nil when an hourly/daily target converts it.
    var answerPeriod: String?
}

/// One átalányadó month. Contributions are monthly liabilities (NAV collects them quarterly); the SZJA advance
/// on cumulative income appears in each quarter's last month. Left is revenue minus these three payments.
struct HungarianPayrollMonth: Equatable {
    let month: Int, revenue: Rational, income: Rational, contributionBase: Rational, socialSecurity: Int64
    let socialContributionTax: Int64, incomeTaxAdvance: Int64, left: Rational
}

/// Hungary 2026: a full-month employee (15% SZJA, 18.5% TB járulék, employer 13% szocho) and a whole-year
/// átalányadózó sole trader with evenly earned revenue and the NAV quarterly göngyölítés of contribution bases.
enum HungarianPayrollRules {
    static let employeeRule = "HU-employee-2026-v1", flatRateRule = "HU-atalanyado-2026-v1"
    static let minimumWage: Int64 = 322800, guaranteedMinimumWage: Int64 = 373200, taxFreeIncome: Int64 = 1936800, youthMonthlyCap: Int64 = 715765, firstMarriageMonthly: Int64 = 33335
    static let revenueCeiling: Int64 = 38736000, retailRevenueCeiling: Int64 = 193680000
}

final class HungarianSalaryArithmetic {
    static let employeeRule = HungarianPayrollRules.employeeRule, flatRateRule = HungarianPayrollRules.flatRateRule
    static let minimumWage = HungarianPayrollRules.minimumWage, guaranteedMinimumWage = HungarianPayrollRules.guaranteedMinimumWage
    static let taxFreeIncome = HungarianPayrollRules.taxFreeIncome, youthMonthlyCap = HungarianPayrollRules.youthMonthlyCap, firstMarriageMonthly = HungarianPayrollRules.firstMarriageMonthly
    static let revenueCeiling = HungarianPayrollRules.revenueCeiling, retailRevenueCeiling = HungarianPayrollRules.retailRevenueCeiling
    static let maxMonthlyGross = Int64(PayrollArithmetic.maxAnnualGross / 12)
    // Rounded net differs from the exact (unrounded) net, which never decreases with gross, by at most
    // 1.5 HUF (employee) and 19 HUF (flat rate: 24 monthly contributions, tax and relief); a lower amount can
    // therefore exceed a higher amount's net by at most twice that.
    static let employeeDipBound: Int64 = 3, flatRateDipBound: Int64 = 40
    private static let scale: Int64 = 3600 // flat-rate quantities in 1/3600 HUF: twelfths of a percentage share, then thirds for quarters
    static let employeeSources = [
        "https://nav.gov.hu/pfile/file?path=/ugyfeliranytu/nezzen-utana/inf_fuz/2026/73.-Szja-adoalap-kedvezmenyek-2026.-03.19",
        "https://njt.hu/jogszabaly/1995-117-00-00",
        "https://njt.hu/jogszabaly/2019-122-00-00",
        "https://njt.hu/jogszabaly/2018-52-00-00",
        "https://njt.hu/jogszabaly/2025-426-20-22"]
    static let flatRateSources = [
        "https://nav.gov.hu/pfile/file?path=/ugyfeliranytu/nezzen-utana/inf_fuz/2026/100.-Az-egyeni-vallalkozok-atalanyadozasanak-alapveto-szabalyai-2026.-02.-20",
        "https://nav.gov.hu/pfile/file?path=/ugyfeliranytu/nezzen-utana/inf_fuz/2026/73.-Szja-adoalap-kedvezmenyek-2026.-03.19",
        "https://njt.hu/jogszabaly/1995-117-00-00",
        "https://njt.hu/jogszabaly/2019-122-00-00",
        "https://njt.hu/jogszabaly/2018-52-00-00",
        "https://njt.hu/jogszabaly/2025-426-20-22"]

    struct Profile: Equatable {
        let children: Int, dependants: Int, youth: Bool, mothers: Bool, firstMarriage: Bool, mainJob: Bool, pensioner: Bool, costRatio: Int, guaranteed: Bool
        var monthlyFamilyFrame: Int64 {
            if children == 0 { return 0 }
            let perChild: Int64
            switch dependants { case 1: perChild = 133340; case 2: perChild = 266660; default: perChild = 440000 }
            return Int64(children) * perChild
        }
        var minimumBase: Int64 { guaranteed ? HungarianSalaryArithmetic.guaranteedMinimumWage : HungarianSalaryArithmetic.minimumWage }
    }

    /// Receives the átalányadó months (C# passes a List<HungarianPayrollMonth>).
    final class MonthLog { var months: [HungarianPayrollMonth] = [] }

    struct Result {
        let gross: Int64, net: Int64, income: Rational, taxable: Rational, allowances: Rational, familyUsed: Rational, taxBase: Rational, tax: Int64
        let socialBase: Rational, socialSecurity: Int64, relief: Int64, szochoBase: Rational, szocho: Int64, employerCost: Int64
    }

    private let budget: ExecutionBudget, token: CancellationToken, money: MoneyArithmetic, context: EvaluationContext, reads: ContextReads
    init(_ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic, _ context: EvaluationContext, _ reads: ContextReads) {
        self.budget = budget; self.token = token; self.money = money; self.context = context; self.reads = reads
    }

    /// Half up to a whole number: (2n + d) / (2d) for nonnegative n.
    private static func round(_ numerator: BigInt, _ denominator: BigInt) throws -> Int64 {
        if numerator.sign < 0 { throw CalcError.arithmetic("Negative Hungarian payroll rounding input") }
        guard let value = ((BigInt(2) * numerator + denominator) / (BigInt(2) * denominator)).int64Value else {
            throw CalcError.arithmetic(CalcError.overflowInt64Message)
        }
        return value
    }
    private static func round(_ numerator: Int64, _ denominator: Int64) throws -> Int64 { try round(BigInt(numerator), BigInt(denominator)) }
    private static func r(_ numerator: Int64, _ denominator: Int64 = 1) throws -> Rational { try Rational(BigInt(numerator), BigInt(denominator)) }

    /// Employee: one full month in whole forints, each amount rounded half up.
    static func employee(_ gross: Int64, _ profile: Profile) throws -> Result {
        let tb = try round(gross * 185, 1000)
        var remaining = gross, allowances: Int64 = 0
        func take(_ cap: Int64) -> Int64 { let used = Swift.min(remaining, cap); remaining -= used; allowances += used; return used }
        if profile.mothers { _ = take(remaining) }
        if profile.youth { _ = take(youthMonthlyCap) }
        if profile.firstMarriage { _ = take(firstMarriageMonthly) }
        let family = take(profile.monthlyFamilyFrame)
        let tax = try round(remaining * 15, 100)
        let relief = Swift.min(tb, try round((profile.monthlyFamilyFrame - family) * 15, 100))
        let szocho = try round(gross * 13, 100)
        return Result(gross: gross, net: gross - tb + relief - tax, income: try r(gross), taxable: try r(gross), allowances: try r(allowances), familyUsed: try r(family),
                      taxBase: try r(remaining), tax: tax, socialBase: try r(gross), socialSecurity: tb, relief: relief, szochoBase: try r(gross), szocho: szocho, employerCost: gross + szocho)
    }

    /// Allowances in statutory order over `months` eligible months, in 1/3600 HUF.
    private static func flatAllowances(_ taxable: Int64, _ months: Int64, _ profile: Profile) -> (allowances: Int64, family: Int64, remaining: Int64) {
        var remaining = taxable, allowances: Int64 = 0
        func take(_ cap: Int64) -> Int64 { let used = Swift.min(remaining, cap); remaining -= used; allowances += used; return used }
        if profile.mothers { _ = take(remaining) }
        if profile.youth { _ = take(months * youthMonthlyCap * scale) }
        if profile.firstMarriage { _ = take(months * firstMarriageMonthly * scale) }
        let family = take(months * profile.monthlyFamilyFrame * scale)
        return (allowances, family, remaining)
    }

    /// Flat rate: whole-year revenue earned evenly, quarterly cumulative contribution bases with a monthly minimum.
    /// When `months` is supplied it receives each month's liabilities, with the SZJA advance on cumulative
    /// quarterly income in the quarter's last month.
    static func flatRate(_ revenue: Int64, _ profile: Profile, _ months: MonthLog? = nil) throws -> Result {
        let monthly = revenue * (100 - Int64(profile.costRatio)) * 3 // monthly income in 1/3600 HUF
        let income = 12 * monthly; let taxFree = taxFreeIncome * scale
        var previous: Int64 = 0, tb: Int64 = 0, szocho: Int64 = 0, eligibleTb: Int64 = 0, advanced: Int64 = 0
        for quarter in Int64(1)...4 {
            let cumulative = Swift.max(0, 3 * quarter * monthly - taxFree)
            let rolled = Swift.max(0, cumulative - previous) / 3 // exact: both terms are multiples of three
            let minimum = profile.mainJob ? profile.minimumBase * scale : 0
            let actual = Swift.max(rolled, minimum)
            let eligible = rolled >= minimum ? actual : Swift.min(minimum, monthly)
            for month in Int64(0)..<3 {
                previous += actual
                var monthTb: Int64 = 0, monthSzocho: Int64 = 0, advance: Int64 = 0
                if !profile.pensioner {
                    monthTb = try round(BigInt(actual) * BigInt(185), BigInt(scale * 1000)); monthSzocho = try round(BigInt(actual) * BigInt(13), BigInt(scale * 100))
                    tb += monthTb; szocho += monthSzocho; eligibleTb += try round(BigInt(eligible) * BigInt(185), BigInt(scale * 1000))
                }
                guard let months else { continue }
                if month == 2 {
                    let due = try round(BigInt(flatAllowances(cumulative, 3 * quarter, profile).remaining) * BigInt(15), BigInt(scale * 100))
                    advance = due - advanced; advanced = due
                }
                let share = try r(revenue, 12)
                months.months.append(HungarianPayrollMonth(month: Int(3 * (quarter - 1) + month + 1), revenue: share, income: try r(monthly, scale),
                    contributionBase: try r(profile.pensioner ? 0 : actual, scale), socialSecurity: monthTb, socialContributionTax: monthSzocho,
                    incomeTaxAdvance: advance, left: try share - (try r(monthTb + monthSzocho + advance))))
            }
        }
        let socialBase = profile.pensioner ? 0 : previous
        let taxable = Swift.max(0, income - taxFree)
        let (allowances, family, remaining) = flatAllowances(taxable, 12, profile)
        let frame = 12 * profile.monthlyFamilyFrame * scale
        let tax = try round(BigInt(remaining) * BigInt(15), BigInt(scale * 100))
        let relief = profile.pensioner ? 0 : Swift.min(eligibleTb, try round(BigInt(frame - family) * BigInt(15), BigInt(scale * 100)))
        return Result(gross: revenue, net: revenue - tax - tb + relief - szocho, income: try r(income, scale), taxable: try r(taxable, scale),
                      allowances: try r(allowances, scale), familyUsed: try r(family, scale), taxBase: try r(remaining, scale), tax: tax,
                      socialBase: try r(socialBase, scale), socialSecurity: tb, relief: relief, szochoBase: try r(socialBase, scale), szocho: szocho, employerCost: revenue)
    }

    private func forward(_ gross: Int64, _ profile: Profile) throws -> Result {
        try budget.step(token); try token.throwIfCancellationRequested()
        return profile.costRatio > 0 ? try HungarianSalaryArithmetic.flatRate(gross, profile) : try HungarianSalaryArithmetic.employee(gross, profile)
    }

    /// Lowest whole-forint gross whose rounded net equals the target, using the bounded rounding dip.
    private func inverse(_ target: Int64, _ low: Int64, _ high: Int64, _ dip: Int64, _ profile: Profile) throws -> Int64 {
        if try forward(high, profile).net < target { throw CalcError.arithmetic("Target net exceeds the supported Hungarian gross bound") }
        let crossing: Int64
        if try forward(low, profile).net >= target { crossing = low }
        else {
            var below = low, above = high // Net(below) < target <= Net(above)
            while above - below > 1 {
                let middle = below + (above - below) / 2
                if try forward(middle, profile).net >= target { above = middle } else { below = middle }
            }
            crossing = above
        }
        var lowest: Int64? = nil
        var gross = crossing - 1
        while gross >= low {
            let net = try forward(gross, profile).net
            if net == target { lowest = gross }
            if net < target - dip { break }
            gross -= 1
        }
        if let lowest { return lowest }
        gross = crossing
        while gross <= high {
            let net = try forward(gross, profile).net
            if net == target { return gross }
            if net > target + dip { break }
            gross += 1
        }
        throw CalcError.arithmetic("No whole-forint amount within the supported Hungarian profile produces this exact net")
    }

    private func options(_ expression: SalaryExpression) throws -> (profile: Profile, options: HungarianSalaryOptions) {
        let hu = expression.hungarian ?? HungarianSalaryOptions()
        var children = 0
        if let de = expression.german {
            var reset = de; reset.children = 0
            if reset != GermanSalaryOptions() { throw CalcError.arithmetic("Tax class, church tax, child allowance, health surcharge, Saxony and childless-surcharge options require German salary rules") }
            children = de.children
        }
        var dependants: Int? = nil; var youth = false; var mainJob = true
        if let ro = expression.romanian {
            var reset = ro; reset.dependants = nil; reset.youthRelief = false; reset.mainJob = true
            if reset != RomanianSalaryOptions() { throw CalcError.arithmetic("School children, basic salary and minimum relief options require Romanian salary rules") }
            dependants = ro.dependants; youth = ro.youthRelief; mainJob = ro.mainJob
        }
        let total = dependants ?? children
        if children > total { throw CalcError.arithmetic("Hungarian beneficiary children must be included in the total dependant count") }
        if total > 0 && children == 0 { throw CalcError.arithmetic("Hungarian family allowance needs the number of beneficiary children, for example with 2 children") }
        if hu.flatRate {
            if expression.employerCost { throw CalcError.arithmetic("Employer cost applies to the Hungarian employee model, not átalányadó") }
            if hu.pensioner && !mainJob { throw CalcError.arithmetic("Choose either pensioner or secondary (without main job) átalányadó status") }
            if hu.guaranteedMinimum && (hu.pensioner || !mainJob) { throw CalcError.arithmetic("The guaranteed minimum base applies only to main-occupation átalányadó") }
        } else {
            if hu.costRatio != nil || hu.guaranteedMinimum || hu.pensioner { throw CalcError.arithmetic("Cost ratio, guaranteed minimum and pensioner options require with átalányadó") }
            if !mainJob { throw CalcError.arithmetic("without main job applies to Hungarian átalányadó (secondary activity), not to the employee model") }
        }
        return (Profile(children: children, dependants: total, youth: youth, mothers: hu.mothersExemption, firstMarriage: hu.firstMarriage, mainJob: mainJob && !hu.pensioner,
                        pensioner: hu.pensioner, costRatio: hu.flatRate ? hu.costRatio ?? 45 : 0, guaranteed: hu.guaranteedMinimum), hu)
    }

    /// `value.ToString("N0", InvariantCulture).Replace(',', ' ')`.
    static func forints(_ value: Int64) -> String { NetFormat.integer(value, "N0").netReplace(",", " ") }

    func evaluate(_ expression: SalaryExpression, _ value: SheetValue, _ origin: String) throws -> PayrollResult {
        let (profile, hu) = try options(expression); let flat = hu.flatRate
        var year = expression.year ?? expression.payrollDate?.year
        if year == nil { reads.dependencies.insert(.date); year = try context.requireToday().year }
        if year != 2026 { throw CalcError.arithmetic("Hungarian salary rules unavailable for \(year!); supported 2026 only") }
        let hadPeriod = value.kind == .earnings
        let period = hadPeriod ? try value.earnings.period : flat ? .year : .month
        if period != .month && period != .year { throw CalcError.arithmetic("Annualize hourly/workday earnings explicitly before applying salary rules") }
        var amount = hadPeriod ? try value.earnings.amount : value
        var outputCurrency: String? = nil; var stamp: CurrencyRateStamp? = nil
        if amount.kind == .money {
            let converted = try money.convert(try amount.money, "HUF"); outputCurrency = "HUF"; stamp = converted.rateStamp; amount = .number(converted.magnitude)
        }
        let number = try amount.number
        if !number.isRational || number.unit != nil || number.isPercentage { throw CalcError.arithmetic("Hungarian salary requires a rational HUF amount without units or percentages") }
        let approximate = number.isApproximate
        // Model unit: employee month, flat-rate year.
        let scalar = try number.scalar
        var unitInput = flat ? (period == .month ? try scalar * Rational(12) : scalar) : (period == .year ? try scalar / Rational(12) : scalar)
        // A currency conversion rarely lands on whole forints; settle it to the nearest forint and disclose that.
        let convertedRounding = outputCurrency != nil && !unitInput.denominator.isOne && unitInput.numerator.sign >= 0
        if convertedRounding { unitInput = Rational(try HungarianSalaryArithmetic.round(unitInput.numerator, unitInput.denominator)) }
        if !unitInput.denominator.isOne || unitInput.numerator.sign < 0 {
            throw CalcError.arithmetic(flat ? "Átalányadó requires nonnegative whole-forint annual revenue" : "Hungarian salary requires nonnegative whole-forint monthly amounts")
        }
        let ceiling = flat ? (profile.costRatio == 90 ? HungarianSalaryArithmetic.retailRevenueCeiling : HungarianSalaryArithmetic.revenueCeiling) : HungarianSalaryArithmetic.maxMonthlyGross
        let input = unitInput.numerator > BigInt(Int64.max / 2) ? Int64.max / 2 : unitInput.numerator.int64Value!
        let forints = HungarianSalaryArithmetic.forints
        if !expression.inverse && input > ceiling {
            throw CalcError.arithmetic(flat ? "Átalányadó revenue limit is \(forints(ceiling)) HUF for 2026 at a \(profile.costRatio)% cost ratio"
                : period == .month && !hadPeriod ? "A plain Hungarian salary is monthly, and \(forints(input)) HUF a month is above the \(forints(ceiling)) HUF limit. For a yearly salary add /year, for example x/year gross in HU"
                : "Hungarian salary is limited to \(forints(ceiling)) HUF a month")
        }
        let gross = expression.inverse ? try inverse(input, 0, ceiling, flat ? HungarianSalaryArithmetic.flatRateDipBound : HungarianSalaryArithmetic.employeeDipBound, profile) : input
        let result = try forward(gross, profile)
        let returned = expression.employerCost ? result.employerCost : expression.inverse ? result.gross : result.net
        let factor = flat ? (period == .month ? try Rational(1, 12) : Rational.one) : (period == .year ? Rational(12) : Rational.one)
        func outputValue(_ forints: Rational) throws -> SheetValue {
            var value = NumericValue(forints); value.displayDecimalPlaces = 4; value.isApproximate = approximate
            guard let outputCurrency else { return .number(value) }
            return .money(try MoneyValue(value, outputCurrency, stamp))
        }
        var output = try outputValue(try Rational(returned) * factor)
        if hadPeriod { output = .earnings(try EarningsValue(output, period)) }
        func f(_ value: Int64) -> String { forints(value) + " HUF" }
        func q(_ value: Rational) throws -> String { try HungarianSalaryArithmetic.display(value) + " HUF" }
        var detail = flat ? try HungarianSalaryArithmetic.flatDetail(expression, origin, profile, result, f, q) : try HungarianSalaryArithmetic.employeeDetail(expression, origin, profile, result, f, q)
        detail += convertedRounding ? "; converted input rounded half up to \(input) whole HUF per \(flat ? "year" : "month")" : ""
        detail += expression.inverse ? "; lowest whole-forint \(flat ? "revenue" : "gross") producing the exact net, verified by recomputing; other amounts may produce the same rounded net" : ""
        detail += approximate ? "; upstream amount is approximate" : "; exact represented amount"
        detail += money.provenance.map { "; " + $0 + "; generic exchange-rate conversion, not a statutory MNB conversion" } ?? ""
        if let target = expression.outputPeriod {
            let rate = hadPeriod ? output : .earnings(try EarningsValue(output, flat ? .year : .month))
            let math = ExactArithmetic(budget, token)
            let converter = EarningsArithmetic(math, money, WorkdayArithmetic(budget, token), context, reads, token)
            output = try converter.convert(rate, target); detail += "; " + (converter.assumption ?? "")
        }
        let sources = flat ? HungarianSalaryArithmetic.flatRateSources : HungarianSalaryArithmetic.employeeSources
        detail += "; rule sources " + sources.joined(separator: "; ")
        let months = Rational(flat ? 1 : 12)
        var deductions = [PayrollDeduction("Personal income tax (SZJA)", try Rational(result.tax) * months),
                          PayrollDeduction("Social security contribution (TB járulék)", try Rational(result.socialSecurity) * months),
                          PayrollDeduction("Family contribution relief", try Rational(-result.relief) * months)]
        if flat { deductions.append(PayrollDeduction("Social contribution tax (szocho)", Rational(result.szocho))) }
        let status: String? = flat ? (profile.pensioner ? "pensioner" : profile.mainJob ? "main occupation" : "secondary") : nil
        var evidenceHu = HungarianPayrollEvidence(profile: flat ? "átalányadó" : "employee", period: flat ? "year" : "month", gross: result.gross, net: result.net,
            income: result.income, taxFreeIncome: flat ? HungarianSalaryArithmetic.taxFreeIncome : 0, taxableIncome: result.taxable, allowances: result.allowances,
            familyAllowanceUsed: result.familyUsed, taxBase: result.taxBase, personalIncomeTax: result.tax, socialSecurityBase: result.socialBase,
            socialSecurity: result.socialSecurity, familyContributionRelief: result.relief, socialContributionTaxBase: result.szochoBase,
            socialContributionTax: result.szocho, employerCost: result.employerCost, children: profile.children, dependants: profile.dependants,
            youthExemption: profile.youth, mothersExemption: profile.mothers, firstMarriage: profile.firstMarriage, costRatio: flat ? profile.costRatio : nil, status: status)
        if flat {
            let schedule = MonthLog(); _ = try HungarianSalaryArithmetic.flatRate(gross, profile, schedule)
            evidenceHu.months = schedule.months
        }
        switch expression.outputPeriod {
        case nil: evidenceHu.answerPeriod = period == .month ? "month" : "year"
        case .month?: evidenceHu.answerPeriod = "month"
        case .year?: evidenceHu.answerPeriod = "year"
        default: evidenceHu.answerPeriod = nil
        }
        var evidence = PayrollEvidence("HU", 2026, flat ? HungarianSalaryArithmetic.flatRateRule : HungarianSalaryArithmetic.employeeRule,
                                       try Rational(result.gross) * months, try Rational(result.net) * months,
                                       try (try result.allowances + Rational(flat ? HungarianSalaryArithmetic.taxFreeIncome : 0)) * months, try result.taxBase * months,
                                       deductions, expression.inverse, approximate,
                                       flat ? "Hungarian 2026 átalányadó tax year; revenue earned evenly, quarterly cumulative contribution bases" : "Hungarian 2026 full-month employee; annual fields project twelve identical months")
        evidence.sources = sources; evidence.hungarian = evidenceHu
        return PayrollResult(output, detail, evidence)
    }

    /// Whole forints with space groups; a fraction shows two truncated decimals and "…".
    private static func display(_ value: Rational) throws -> String {
        let (whole, remainder) = value.numerator.quotientAndRemainder(dividingBy: value.denominator)
        let text = netGroupedInteger(whole).netReplace(",", " ")
        if remainder.isZero { return text }
        guard let hundredths = (remainder * BigInt(100) / value.denominator).int64Value else { throw CalcError.arithmetic(CalcError.overflowInt64Message) }
        return text + "." + NetFormat.integer(hundredths, "00") + "…"
    }
    /// `BigInteger.ToString("N0", InvariantCulture)`.
    private static func netGroupedInteger(_ value: BigInt) -> String {
        let digits = value.magnitude.description
        var grouped = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        return value.sign < 0 ? "-" + grouped : grouped
    }
    private static func allowances(_ profile: Profile) -> String {
        (profile.mothers ? "mothers' exemption asserted (under-30 or two/three/four-child mothers, no cap); " : "") +
        (profile.youth ? "under-25 exemption asserted (715 765 HUF monthly cap); " : "") +
        (profile.firstMarriage ? "first-marriage allowance asserted (33 335 HUF monthly base); " : "") +
        (profile.children > 0 ? "family allowance for \(profile.children) beneficiary of \(profile.dependants) dependant(s), \(forints(profile.monthlyFamilyFrame)) HUF monthly base, claimed in full by this person; " : "") +
        (profile.mothers || profile.youth || profile.firstMarriage || profile.children > 0 ? "" : "no tax allowances; ")
    }
    private static func employeeDetail(_ expression: SalaryExpression, _ origin: String, _ profile: Profile, _ r: Result, _ f: (Int64) -> String, _ q: (Rational) throws -> String) throws -> String {
        var text = "Hungarian salary \(expression.inverse ? "net to gross" : "gross to net"); HU from \(origin); \(employeeRule); 2026 full-month employee, monthly whole-forint amounts; " + allowances(profile)
        text += "gross \(f(r.gross)); TB járulék 18.5% \(f(r.socialSecurity)); allowances \(try q(r.allowances)); SZJA base \(try q(r.taxBase)); SZJA 15% \(f(r.tax))"
        text += r.relief > 0 ? "; family contribution relief \(f(r.relief)) (15% of unused family allowance, at most the TB járulék)" : ""
        text += "; net \(f(r.net)); employer szocho 13% \(f(r.szocho)); employer cost \(f(r.employerCost))"
        text += "; each amount rounded half up to whole forints; allowances in statutory order; no benefits, cafeteria, part-month, disability (személyi) allowance, KIVA or other employer relief, voluntary funds or minimum-base cases"
        text += "; bare amounts default to monthly HUF model units; yearly amounts are twelve identical months"
        return text
    }
    private static func flatDetail(_ expression: SalaryExpression, _ origin: String, _ profile: Profile, _ r: Result, _ f: (Int64) -> String, _ q: (Rational) throws -> String) throws -> String {
        var text = "Hungarian átalányadó \(expression.inverse ? "net to revenue" : "revenue to net"); HU from \(origin); \(flatRateRule); 2026 whole tax year, "
        text += profile.pensioner ? "pensioner (no TB járulék or szocho)"
            : profile.mainJob ? "main occupation with monthly minimum base \(profile.guaranteed ? "guaranteed minimum wage 373 200 HUF (activity requires secondary qualification)" : "minimum wage 322 800 HUF")"
            : "secondary activity beside 36-hour employment or full-time study (no minimum base)"
        text += "; cost ratio \(profile.costRatio)%; revenue \(f(r.gross)); income \(try q(r.income)); tax-free part \(f(taxFreeIncome)); taxable income \(try q(r.taxable)); " + allowances(profile)
        text += "SZJA base \(try q(r.taxBase)); SZJA 15% \(f(r.tax)); annual TB járulék and szocho base \(try q(r.socialBase)); TB járulék 18.5% \(f(r.socialSecurity))"
        text += (r.relief > 0 ? "; family contribution relief \(f(r.relief))" : "") + "; szocho 13% \(f(r.szocho)); net \(f(r.net))"
        text += "; net is revenue less SZJA, contributions and szocho only, before actual business costs, local business tax (HIPA), VAT and chamber fees"
        text += "; revenue earned evenly over a full insured year, quarterly cumulative (göngyölítéses) bases with monthly contributions rounded half up to whole forints; no suspension, sick pay or part-year activity"
        text += "; bare amounts are annual revenue; monthly amounts annualize by twelve"
        return text
    }
}
