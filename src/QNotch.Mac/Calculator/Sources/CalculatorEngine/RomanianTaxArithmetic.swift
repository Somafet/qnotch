import Foundation

// Port of RomanianTaxArithmetic.cs: explicit 2026 Romanian rate models (PFA, micro, dividends, securities, crypto, CASS).

struct RomanianTaxCharge: Equatable {
    let name: String, amount: Rational
    init(_ name: String, _ amount: Rational) { self.name = name; self.amount = amount }
}
struct RomanianTaxEvidence: Equatable {
    let model: String, taxYear: Int, ruleVersion: String, inputAmount: Rational, taxableAmount: Rational
    let charges: [RomanianTaxCharge], totalLiability: Rational?, remainingCash: Rational?, items: Int, inputApproximate: Bool, basis: String
    var pensionBase: Rational?
    var healthBase: Rational?
    var deductibleHealth: Rational?
    var sources: [String] = []
}
struct RomanianTaxResult {
    let value: SheetValue, assumption: String, evidence: RomanianTaxEvidence
}

/// Explicit 2026 Romanian rate models. Represented amounts stay exact before filing/withholding rounding.
final class RomanianTaxArithmetic {
    static let year = 2026
    static let januaryMinimum = 4050
    private let budget: ExecutionBudget, token: CancellationToken
    private let math: ExactArithmetic
    private var approximate = false, monetary = false
    private var stamp: CurrencyRateStamp?
    private static let bound = Rational(100_000_000)
    private static let six = Rational(januaryMinimum * 6), twelve = Rational(januaryMinimum * 12), twentyFour = Rational(januaryMinimum * 24), seventyTwo = Rational(januaryMinimum * 72)
    private static let code = "https://static.anaf.ro/static/10/Anaf/legislatie/Cod_fiscal_norme_2023.htm"
    private static let law239 = "https://static.anaf.ro/static/10/Anaf/legislatie/L_239_2025.pdf"
    private static let law141 = "https://static.anaf.ro/static/10/Anaf/legislatie/L_141_2025.pdf"
    private static let oug89 = "https://static.anaf.ro/static/10/Anaf/legislatie/OUG_89_2025.pdf"

    init(_ budget: ExecutionBudget, _ token: CancellationToken) { self.budget = budget; self.token = token; math = ExactArithmetic(budget, token) }

    static func isFunction(_ name: String) -> Bool {
        ["pfanetro", "pfataxro", "microtaxro", "dividendtaxro", "dividendcashro", "stocktaxro", "brokertaxro", "brokergainsro", "cryptotaxro", "investmentcassro"].contains(name.netLower)
    }
    static func validateArity(_ name: String, _ count: Int) throws {
        let (minimum, maximum): (Int, Int)
        switch name.netLower {
        case "pfanetro", "pfataxro": (minimum, maximum) = (3, 5)
        case "microtaxro", "brokertaxro": (minimum, maximum) = (3, 3)
        case "stocktaxro": (minimum, maximum) = (2, 3)
        default: (minimum, maximum) = (2, 2)
        }
        if count < minimum || count > maximum { throw CalcError.format("\(name) expects \(minimum)–\(maximum) arguments; tax year is explicit") }
    }
    private func add(_ a: Rational, _ b: Rational) throws -> Rational { try budget.step(token); return try math.add(ExactNumber(a), ExactNumber(b)).rational }
    private func subtract(_ a: Rational, _ b: Rational) throws -> Rational { try budget.step(token); return try math.subtract(ExactNumber(a), ExactNumber(b)).rational }
    private func multiply(_ a: Rational, _ b: Rational) throws -> Rational { try budget.step(token); return try math.multiply(ExactNumber(a), ExactNumber(b)).rational }
    private func compare(_ a: Rational, _ b: Rational) throws -> Int {
        try budget.step(token); return BigInt.compare(a.numerator * b.denominator, b.numerator * a.denominator)
    }
    private static func positive(_ a: Rational) -> Rational { a.numerator.sign < 0 ? .zero : a }
    private func min(_ a: Rational, _ b: Rational) throws -> Rational { try compare(a, b) <= 0 ? a : b }
    private func checked(_ a: Rational) throws -> Rational {
        if try compare(a.abs, RomanianTaxArithmetic.bound) > 0 { throw CalcError.arithmetic("Romanian tax amount/aggregate exceeds 100,000,000 model units") }
        return a
    }
    private static func scalar(_ value: SheetValue) throws -> NumericValue {
        let number = try value.number
        if !number.isRational || number.unit != nil || number.isPercentage { throw CalcError.arithmetic("Romanian tax inputs require rational amounts without units or percentages") }
        return number
    }
    private func cash(_ value: SheetValue, _ nonnegative: Bool = false) throws -> Rational {
        try budget.step(token); let number: NumericValue
        if value.kind == .money {
            let cash = try value.money
            if cash.currency != "RON" { throw CalcError.arithmetic("Romanian tax cash inputs must already be RON; choose any required statutory currency conversion explicitly") }
            if let stamp, cash.rateStamp != nil, stamp.key != cash.rateSnapshotKey { throw CalcError.arithmetic("Romanian tax inputs use conflicting currency snapshots") }
            stamp = stamp ?? cash.rateStamp; monetary = true; number = cash.magnitude
            if !number.isRational || number.unit != nil || number.isPercentage { throw CalcError.arithmetic("Romanian tax requires monetary amounts without physical rate units") }
        } else { number = try RomanianTaxArithmetic.scalar(value) }
        approximate = approximate || number.isApproximate; let amount = try checked(try number.scalar)
        if nonnegative && amount.numerator.sign < 0 { throw CalcError.arithmetic("This Romanian tax input must be nonnegative") }
        return amount
    }
    private static func integer(_ value: SheetValue, _ maximum: Int, _ name: String) throws -> Int {
        let number = try scalar(value); let amount = try number.scalar
        if number.isApproximate || !amount.denominator.isOne || amount.numerator.sign < 0 || amount.numerator > BigInt(maximum) {
            throw CalcError.arithmetic(name + " requires an exact bounded whole number")
        }
        return amount.numerator.intValue!
    }
    private func cashItems(_ value: SheetValue, _ nonnegative: Bool = false) throws -> [Rational] {
        let values = value.kind == .list ? try value.list.values : [value]
        return try values.map { try cash($0, nonnegative) }
    }
    private func sum(_ values: [Rational]) throws -> Rational {
        var result = Rational.zero; for value in values { result = try add(result, value) }; return try checked(result)
    }
    private func output(_ value: Rational) throws -> SheetValue {
        var number = NumericValue(value); number.displayDecimalPlaces = 4; number.isApproximate = approximate
        return monetary ? .money(try MoneyValue(number, "RON", stamp)) : .number(number)
    }
    /// C# `bool.ToString()`.
    private static func text(_ value: Bool) -> String { value ? "True" : "False" }

    func function(_ name: String, _ args: [SheetValue]) throws -> RomanianTaxResult {
        try RomanianTaxArithmetic.validateArity(name, args.count); let key = name.netLower
        let yearIndex = ["pfanetro", "pfataxro", "microtaxro", "brokertaxro"].contains(key) ? 2 : 1
        if try RomanianTaxArithmetic.integer(args[yearIndex], 9999, "Tax year") != RomanianTaxArithmetic.year {
            throw CalcError.arithmetic("Romanian tax models support explicit tax year 2026 only")
        }
        var charges: [RomanianTaxCharge] = []; var input = Rational.zero, taxable = Rational.zero, total = Rational.zero, returned = Rational.zero
        var remaining: Rational? = nil, pensionBase: Rational? = nil, healthBase: Rational? = nil, deductibleHealth: Rational? = nil
        var items = 1; let scope: String; let sources: [String]
        let code = RomanianTaxArithmetic.code, law239 = RomanianTaxArithmetic.law239
        if key == "pfanetro" || key == "pfataxro" {
            let receipts = try cash(args[0], true); let expenses = try cash(args[1], true); input = try subtract(receipts, expenses)
            let casExempt = args.count > 3 ? try RomanianTaxArithmetic.integer(args[3], 1, "CAS exemption flag") == 1 : false
            let floorExempt = args.count > 4 ? try RomanianTaxArithmetic.integer(args[4], 1, "CASS floor exemption flag") == 1 : false
            let positive = RomanianTaxArithmetic.positive(input)
            let pension = try casExempt || compare(positive, RomanianTaxArithmetic.twelve) < 0 ? Rational.zero
                : compare(positive, RomanianTaxArithmetic.twentyFour) < 0 ? RomanianTaxArithmetic.twelve : RomanianTaxArithmetic.twentyFour
            pensionBase = pension
            let cas = try multiply(pension, Rational(1, 4))
            let health = try min(positive, RomanianTaxArithmetic.seventyTwo); healthBase = health
            let cass = try multiply(health, Rational(1, 10)); deductibleHealth = cass
            let topUp = try !floorExempt && positive.numerator.sign > 0 && compare(positive, RomanianTaxArithmetic.six) < 0 ? try subtract(Rational(2430), cass) : Rational.zero
            taxable = RomanianTaxArithmetic.positive(try subtract(try subtract(positive, cas), cass)); let income = try multiply(taxable, Rational(1, 10))
            charges += [RomanianTaxCharge("Income tax", income), RomanianTaxCharge("CAS minimum pension", cas), RomanianTaxCharge("CASS on income", cass),
                        RomanianTaxCharge("CASS nondeductible floor top-up", topUp)]
            total = try sum(charges.map(\.amount)); let cashLeft = try subtract(input, total); remaining = cashLeft; returned = key == "pfanetro" ? cashLeft : total
            scope = "Annual single-source PFA real-system model; receipts less eligible expenses excluding social contributions; no other independent/IP/sports income, loss carryforward, foreign credit, voluntary/higher CAS base or norm-of-income regime; minimum mandatory CAS base; CAS exemption asserted=" + RomanianTaxArithmetic.text(casExempt) + ", CASS floor exception asserted=" + RomanianTaxArithmetic.text(floorExempt) +
                "; a floor exception removes only the top-up, not 10% income CASS; January minimum 4050 RON fixes all 2026 annual thresholds; CASS income cap 291600 RON; floor top-up is not income-tax deductible; negative/zero profit has no mandatory contributions in this profile"
            sources = [code, law239, "https://static.anaf.ro/static/10/Anaf/legislatie/HG_1506_2024.pdf"]
        } else if key == "microtaxro" {
            let bases = try cashItems(args[0], true)
            if bases.count > 4 { throw CalcError.arithmetic("Micro tax accepts one quarter base or at most four quarterly bases") }
            items = bases.count; input = try sum(bases); taxable = input
            let group = args[1]
            let number = try group.kind == .money && group.money.currency == "EUR" ? group.money.magnitude : RomanianTaxArithmetic.scalar(group)
            if try !number.isRational || number.unit != nil || number.isPercentage || number.isApproximate || number.scalar.numerator.sign < 0 || compare(number.scalar, Rational(100000)) > 0 {
                throw CalcError.arithmetic("Eligible 2026 micro profile requires explicit annual linked-group turnover of 0–100000 EUR; threshold exit needs quarterly profit-tax treatment")
            }
            total = try multiply(taxable, Rational(1, 100)); returned = total; charges.append(RomanianTaxCharge("Micro-company turnover tax", total))
            scope = "Eligible Romanian 2026 micro regime asserted, including employment, ownership, filings and exclusions; Article 53 tax bases supplied for one quarter or up to four quarters; annual linked-group turnover declared \(try number.scalar) EUR using the statutory prior-year-end valuation, not a live exchange rate; this is company tax only, with no inferred distributable profit, dividends, payroll, credits or threshold-exit switch"
            sources = [code, RomanianTaxArithmetic.oug89, "https://static.anaf.ro/static/3/Cluj/20260402144800_cj_micro_02apr2026.pdf"]
        } else if key == "dividendtaxro" || key == "dividendcashro" {
            let amounts = try cashItems(args[0], true); items = amounts.count; input = try sum(amounts); taxable = input; total = try multiply(taxable, Rational(16, 100))
            let cashLeft = try subtract(input, total); remaining = cashLeft
            charges.append(RomanianTaxCharge("Dividend income tax", total)); returned = key == "dividendcashro" ? cashLeft : total
            scope = "Romanian resident individual, dividends distributed and paid in 2026; 16% income-tax model; excludes 2025 interim distributions, foreign credits and exempt corporate recipients; dividendCashRO is cash after income tax only, BEFORE any aggregated investment CASS; paid dividends after withholding are the ordinary Article 170 dividend assessment input"
            sources = [code, RomanianTaxArithmetic.law141]
        } else if key == "stocktaxro" {
            let gains = try cashItems(args[0]); items = gains.count; input = try sum(gains); let carry = args.count > 2 ? try cash(args[2], true) : Rational.zero
            let used = try min(carry, try multiply(RomanianTaxArithmetic.positive(input), Rational(70, 100))); taxable = try subtract(RomanianTaxArithmetic.positive(input), used)
            total = try multiply(taxable, Rational(16, 100)); returned = total; charges.append(RomanianTaxCharge("Annual securities income tax", total))
            scope = "Annual non-withholding securities/investment-gold regime, one homogeneous eligible country/source pool; signed current-year net gains/losses, plus declared valid carryforward subject to 70% cap; used carryforward \(used) RON; no cross-country pooling, legacy-loss expiry/order, foreign credits or qualifying-intermediary treatment inferred; investment CASS uses the applicable current gain basis before prior-loss carryforward, separately"
            sources = [code, law239]
        } else if key == "brokertaxro" || key == "brokergainsro" {
            let gains = try cashItems(args[0]); items = gains.count; input = try sum(gains); taxable = try sum(gains.map(RomanianTaxArithmetic.positive))
            if key == "brokergainsro" {
                returned = taxable
                scope = "Positive realized gains for the qualifying-intermediary regime; losses are not netted against gains; helper returns gains, not a tax or final take-home amount; the caller determines the complete annual investment CASS assessment"
            } else {
                let days = args[1].kind == .list ? try args[1].list.values : [args[1]]
                if days.count != 1 && days.count != gains.count { throw CalcError.arithmetic("Broker holding-day list must match gains, or supply one day count for all trades") }
                if days.isEmpty && !gains.isEmpty { throw CalcError.arithmetic("Missing broker holding days") }
                let periods = try days.map { try RomanianTaxArithmetic.integer($0, 100000, "Holding days") }
                var shortTax = Rational.zero, longTax = Rational.zero
                for i in 0..<gains.count {
                    try budget.step(token); let longHeld = periods[periods.count == 1 ? 0 : i] >= 365
                    let tax = try multiply(RomanianTaxArithmetic.positive(gains[i]), Rational(longHeld ? 3 : 6, 100))
                    if longHeld { longTax = try add(longTax, tax) } else { shortTax = try add(shortTax, tax) }
                }
                charges += [RomanianTaxCharge("Broker gains held under 365 days", shortTax), RomanianTaxCharge("Broker gains held at least 365 days", longTax)]
                total = try add(shortTax, longTax); returned = total
                scope = "Qualifying Article 96.1 intermediary regime; 6% per positive realized gain below 365 holding days, 3% from 365 days inclusive; losses do not offset tax; supplied whole holding days and cost-adjusted gains must reflect the applicable lot/FIFO and acquisition-date rules; no lot matching or CASS is inferred"
            }
            sources = [code, law239]
        } else if key == "cryptotaxro" {
            let gains = try cashItems(args[0]); items = gains.count; input = try sum(gains); let positive = try sum(gains.map(RomanianTaxArithmetic.positive))
            taxable = try compare(positive, Rational(600)) <= 0 ? try sum(try gains.filter { try compare($0, Rational(200)) >= 0 }) : positive
            total = try multiply(taxable, Rational(16, 100)); returned = total; charges.append(RomanianTaxCharge("Crypto gain income tax", total))
            scope = "Complete annual realized transaction gains after acquisition and direct costs; 16% on positive gains without loss netting; only gains STRICTLY below 200 RON are exempt when the entire year's positive gains total at most 600 RON; no wallet cost basis, lot matching, currency conversion or aggregated CASS assessment is inferred"
            sources = [code, law239]
        } else {
            let bases = try cashItems(args[0], true); items = bases.count; input = try sum(bases)
            let health = try compare(input, RomanianTaxArithmetic.six) < 0 ? Rational.zero : compare(input, RomanianTaxArithmetic.twelve) < 0 ? RomanianTaxArithmetic.six
                : compare(input, RomanianTaxArithmetic.twentyFour) < 0 ? RomanianTaxArithmetic.twelve : RomanianTaxArithmetic.twentyFour
            healthBase = health
            taxable = health; total = try multiply(taxable, Rational(1, 10)); returned = total; charges.append(RomanianTaxCharge("Aggregated investment/other-income CASS", total))
            scope = "One annual aggregate of already prepared eligible Article 155(c–h)/170 assessment amounts; 6/12/24 January minimum-wage thresholds 24300/48600/97200 RON; do not apply once per asset/category; PFA health contributions are a SEPARATE income stream; dividend assessment ordinarily uses paid dividends after withholding; caller prepares each other category's statutory gain/income basis and exemptions; no exemption, prior-payment credit, dividend timing or foreign-currency valuation is inferred"
            sources = [code, "https://static.anaf.ro/static/10/Anaf/legislatie/HG_1506_2024.pdf"]
        }
        let family: String
        switch key {
        case "pfanetro", "pfataxro": family = "PFA-real"
        case "microtaxro": family = "micro"
        case _ where key.hasPrefix("dividend"): family = "dividend"
        case "stocktaxro": family = "securities-annual"
        case _ where key.hasPrefix("broker"): family = "securities-broker"
        case "cryptotaxro": family = "crypto"
        default: family = "investment-CASS"
        }
        let rule = "RO-" + family + "-2026-v1"
        let basis = "Exact represented rate-model arithmetic BEFORE statutory return, per-payment, withholding and whole-leu rounding; cash model units RON, input lists are complete within the declared model; no filing or eligibility certification"
        let liability: Rational? = key == "brokergainsro" ? nil : total
        let label: String
        switch key {
        case "pfanetro": label = "Romanian PFA cash after modeled taxes"
        case "pfataxro": label = "Romanian PFA tax and contributions"
        case "microtaxro": label = "Romanian eligible micro-company tax"
        case "dividendtaxro": label = "Romanian dividend income tax"
        case "dividendcashro": label = "Romanian dividends after income tax, before CASS"
        case "stocktaxro": label = "Romanian annual securities income tax"
        case "brokertaxro": label = "Romanian qualifying-broker gains tax"
        case "brokergainsro": label = "Romanian qualifying-broker positive gains"
        case "cryptotaxro": label = "Romanian realized crypto gain tax"
        default: label = "Romanian annual aggregated investment CASS"
        }
        var detail = label + ", 2026; before filing/withholding rounding; rule " + rule + "; " + scope + "; " + basis + "; input \(input) RON; taxable/assessment base \(taxable) RON; "
        detail += charges.map { $0.name + " \($0.amount) RON" }.joined(separator: "; ")
        detail += liability.map { "; total modeled liability \($0) RON" } ?? "; tax liability not calculated by this gain helper"
        detail += remaining.map { "; modeled remaining cash \($0) RON" } ?? ""
        detail += approximate ? "; upstream represented input is approximate" : "; exact represented input"
        detail += stamp.map { "; upstream currency snapshot " + $0.provider + " as of " + $0.asOf.description + "; not a statutory BNR valuation certificate" } ?? ""
        detail += "; sources " + sources.joined(separator: "; ")
        var evidence = RomanianTaxEvidence(model: key, taxYear: RomanianTaxArithmetic.year, ruleVersion: rule, inputAmount: input, taxableAmount: taxable, charges: charges,
                                           totalLiability: liability, remainingCash: remaining, items: items, inputApproximate: approximate, basis: basis)
        evidence.pensionBase = pensionBase; evidence.healthBase = healthBase; evidence.deductibleHealth = deductibleHealth; evidence.sources = sources
        return RomanianTaxResult(value: try output(returned), assumption: detail, evidence: evidence)
    }
}
