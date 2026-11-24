import Foundation

/// CAGR evidence: the term in years, (ending/initial)^denominator(years), the root degree numerator(years),
/// and the IRR certificate when the root is neither rational nor a square root.
struct GrowthEvidence: Hashable {
    let years: Rational, poweredRatio: Rational, rootDegree: Int
    var root: IrrEvidence?
}

extension FinancialArithmetic {
    static func isPlanningFunction(_ name: String) -> Bool {
        ["cagr", "roi", "realreturn", "fire", "breakeven", "sln", "ddb", "syd"].contains(name.netLower)
    }
    static func validatePlanningArity(_ name: String, _ count: Int) throws {
        let (minimum, maximum): (Int, Int)
        switch name.netLower {
        case "roi", "realreturn": (minimum, maximum) = (2, 2)
        case "fire": (minimum, maximum) = (1, 2)
        case "ddb": (minimum, maximum) = (4, 5)
        case "syd": (minimum, maximum) = (4, 4)
        default: (minimum, maximum) = (3, 3)
        }
        if count < minimum || count > maximum { throw CalcError.format("\(name) expects \(minimum)–\(maximum) arguments") }
    }
    private static func nonnegative(_ value: Rational, _ input: String) throws {
        if value.sign < 0 { throw CalcError.arithmetic(input + " must be nonnegative") }
    }
    func planningAssumption(_ detail: String) -> String {
        detail + "; represented amounts retained; display rounding is separate; " +
            (approximate ? "upstream input or bounded financial arithmetic is approximate" : "exact represented inputs") + (money.provenance.map { "; " + $0 } ?? "")
    }
    func planningSentence(_ expression: PlanningSentenceExpression, _ inputs: [SheetValue]) throws -> FinancialResult {
        var args = inputs
        if expression.annualScale != 1 {
            try setTemplate(Array(args.prefix(1)))
            let annual = try multiply(try cash(args[0]), Rational(expression.annualScale))
            args[0] = try output(annual)
        }
        var result = try planningFunction(expression.name, args)
        result.assumption += expression.name == "fire" ? "; source spending per " + expression.period + ", annualized by " + String(expression.annualScale) :
            "; straight-line charge per " + expression.period
        return result
    }
    private func percent(_ value: Rational) -> SheetValue {
        .number(NumericValue(value, isPercentage: true).with { $0.isApproximate = approximate; $0.displayDecimalPlaces = 4 })
    }
    private func months(_ value: SheetValue) throws -> Int {
        if case .calendarPeriod(let period) = value {
            if period.days != 0 || period.months < 1 || period.months > 1200 { throw CalcError.arithmetic("Growth term must contain 1–1200 whole calendar months") }
            return period.months
        }
        let years = try plain(value); let months = try multiply(years, Rational(12))
        if try value.number.isApproximate || !months.denominator.isOne || months.numerator < 1 || months.numerator > 1200 {
            throw CalcError.arithmetic("Growth years must resolve to 1–1200 exact whole months")
        }
        return months.numerator.intValue!
    }
    private func power(_ value: Rational, _ exponent: Int) throws -> Rational {
        var result = Rational.one, value = value, exponent = exponent
        while exponent > 0 {
            try budget.step(token)
            if exponent & 1 != 0 { result = try multiply(result, value) }
            exponent >>= 1
            if exponent > 0 { value = try multiply(value, value) }
        }
        return result
    }
    /// floor(value^(1/degree)) by bisection on exact powers.
    private func integerRoot(_ value: BigInt, _ degree: Int) throws -> BigInt {
        if value <= 1 || degree == 1 { return value }
        var lower = BigInt.zero, upper = BigInt.one << ((value.bitLength + degree - 1) / degree)
        while upper - lower > 1 {
            try budget.step(token); let middle = (lower + upper) / 2
            if try comparePower(middle, degree, value) <= 0 { lower = middle } else { upper = middle }
        }
        return try comparePower(upper, degree, value) == 0 ? upper : lower
    }
    /// The sign of value^exponent - target, stopping early once the power exceeds the target.
    private func comparePower(_ value: BigInt, _ exponent: Int, _ target: BigInt) throws -> Int {
        var result = BigInt.one, value = value, exponent = exponent
        while exponent > 0 {
            try budget.step(token)
            if exponent & 1 != 0 { result *= value; if result > target { return 1 } }
            exponent >>= 1
            if exponent > 0 { value *= value; if value > target { value = target + 1 } }
        }
        return BigInt.compare(result, target).signum()
    }
    func planningFunction(_ name: String, _ args: [SheetValue]) throws -> FinancialResult {
        let key = name.netLower
        if key == "realreturn" {
            let nominal = try plain(args[0], true); let inflation = try self.rate(args[1])
            if nominal.numerator < -nominal.denominator { throw CalcError.arithmetic("Nominal return must be at least -100%") }
            let result = try subtract(try divide(try add(.one, nominal), try add(.one, inflation)), .one)
            return FinancialResult(percent(result), planningAssumption("Real return = (1 + nominal return) / (1 + inflation) - 1; both inputs describe the same period; no simple percentage subtraction"))
        }
        if key == "fire" {
            try setTemplate(Array(args.prefix(1))); let spending = try cash(args[0]); try FinancialArithmetic.nonnegative(spending, "Annual spending")
            let withdrawal = args.count == 2 ? try plain(args[1], true) : try Rational(1, 25)
            if withdrawal.sign <= 0 || withdrawal.numerator > withdrawal.denominator { throw CalcError.arithmetic("Withdrawal rate must be greater than 0% and at most 100%") }
            let target = try divide(spending, withdrawal)
            return FinancialResult(try output(target), planningAssumption("FIRE target = annual spending / chosen withdrawal rate; rate " + (try NumericValue(withdrawal, isPercentage: true).display) +
                (args.count == 1 ? " (default model assumption)" : " (explicit)") + "; fixed arithmetic target, no portfolio path or withdrawal guarantee"))
        }
        if key == "roi" || key == "cagr" {
            try setTemplate(Array(args.prefix(2))); let start = try cash(args[0]); let end = try cash(args[1])
            if start.sign <= 0 { throw CalcError.arithmetic("Initial value must be positive") }
            try FinancialArithmetic.nonnegative(end, "Ending value"); let ratio = try divide(end, start)
            if key == "roi" {
                return FinancialResult(percent(try subtract(ratio, .one)), planningAssumption("ROI = (ending value - initial value) / initial value; endpoint total return, not annualized; include desired income in ending value explicitly"))
            }
            let months = try self.months(args[2]); let years = try Rational(months, 12)
            let degree = years.numerator.intValue!, power = years.denominator.intValue!
            let powered = try self.power(ratio, power); var evidence = GrowthEvidence(years: years, poweredRatio: powered, rootDegree: degree, root: nil)
            let assumption = "CAGR = (ending / initial)^(1 / years) - 1; " + years.description + " calendar years; endpoint compound growth with no intermediate deposits/withdrawals; annualized"
            if end.isZero { return FinancialResult(percent(try Rational(-1, 1)), planningAssumption(assumption + "; total loss"), growth: evidence) }
            let numerator = try integerRoot(powered.numerator, degree); let denominator = try integerRoot(powered.denominator, degree)
            if try comparePower(numerator, degree, powered.numerator) == 0, try comparePower(denominator, degree, powered.denominator) == 0 {
                return FinancialResult(percent(try subtract(try Rational(numerator, denominator), .one)), planningAssumption(assumption + "; verified exact rational root"), growth: evidence)
            }
            if degree == 2 {
                let math = ExactArithmetic(budget, token); let root = try math.squareRoot(ExactNumber(powered)); let exact = try math.subtract(root, ExactArithmetic.one)
                let value = NumericValue(exact, isPercentage: true).with { $0.isApproximate = approximate; $0.displayDecimalPlaces = 4 }
                return FinancialResult(.number(value), planningAssumption(assumption + "; exact real square root retained"), growth: evidence)
            }
            // (1+r)^degree = powered: the discount polynomial -1 + powered*q^degree has one positive root.
            var flows = [Rational](repeating: .zero, count: degree + 1); flows[0] = Rational(-1); flows[degree] = powered
            let solved = try IrrSolver(budget, token).solve(flows, try Rational(1, 10))
            var rootEvidence = solved.evidence; rootEvidence.inputApproximate = approximate
            evidence.root = rootEvidence
            let selected = rootEvidence.roots[0]
            let value = NumericValue(solved.rate, isPercentage: true).with { $0.isApproximate = approximate || !selected.exact; $0.displayDecimalPlaces = 4 }
            return FinancialResult(.number(value), planningAssumption(assumption + "; positive accumulation factor isolated with certified represented-rate interval and stable four-decimal percentage display; " + rootEvidence.method), growth: evidence)
        }
        if key == "breakeven" {
            try setTemplate(args); let fixedCost = try cash(args[0]); let price = try cash(args[1]); let cost = try cash(args[2])
            try FinancialArithmetic.nonnegative(fixedCost, "Fixed cost"); try FinancialArithmetic.nonnegative(price, "Unit price"); try FinancialArithmetic.nonnegative(cost, "Unit variable cost")
            let margin = try subtract(price, cost)
            if !fixedCost.isZero && margin.sign <= 0 { throw CalcError.arithmetic("No finite positive-volume break-even with nonpositive unit contribution") }
            let units = fixedCost.isZero ? Rational.zero : try divide(fixedCost, margin)
            let division = units.numerator.quotientAndRemainder(dividingBy: units.denominator)
            let whole = division.remainder.isZero ? division.quotient : division.quotient + 1
            return FinancialResult(.number(NumericValue(units).with { $0.isApproximate = approximate; $0.displayDecimalPlaces = 4 }),
                planningAssumption("Break-even units = fixed cost / (unit price - unit variable cost); continuous quantity retained; whole-unit coverage threshold " + whole.description + "; matching cost period and constant unit economics assumed"))
        }
        try setTemplate(Array(args.prefix(2))); let initial = try cash(args[0]); let salvage = try cash(args[1])
        try FinancialArithmetic.nonnegative(initial, "Asset cost"); try FinancialArithmetic.nonnegative(salvage, "Salvage value")
        let basis = try subtract(initial, salvage)
        if basis.sign < 0 { throw CalcError.arithmetic("Salvage value cannot exceed asset cost") }
        if key == "sln" {
            let life = try plain(args[2])
            if try life.sign <= 0 || life.numerator > 1200 * life.denominator || args[2].number.isApproximate {
                throw CalcError.arithmetic("SLN useful life must be an exact positive value at most 1200 periods")
            }
            let result = try divide(basis, life)
            return FinancialResult(try output(result), planningAssumption("Straight-line charge = (cost - salvage) / useful life; amount per stated life period; no jurisdictional tax schedule inferred"))
        }
        let periods = try self.periods(args[2], false); let period = try self.periods(args[3], false)
        if period > periods { throw CalcError.arithmetic("Depreciation period cannot exceed useful life") }
        if key == "syd" {
            let charge = try multiply(basis, try Rational(BigInt(2 * (periods - period + 1)), BigInt(periods) * BigInt(periods + 1)))
            return FinancialResult(try output(charge), planningAssumption("SYD charge = (cost - salvage) * (life - period + 1) / (life*(life+1)/2); period " + String(period) + " of " + String(periods) + "; no jurisdictional tax schedule inferred"))
        }
        let factor = args.count == 5 ? try plain(args[4]) : Rational(2)
        if factor.sign <= 0 { throw CalcError.arithmetic("Declining-balance factor must be positive") }
        let rate = try divide(factor, Rational(periods)); var balance = initial; var expense = Rational.zero; var opening = initial
        for _ in 0..<period {
            try budget.step(token); opening = balance
            let available = try subtract(balance, salvage); let candidate = try multiply(balance, rate)
            if available.sign <= 0 { expense = .zero; balance = salvage }
            else {
                expense = (try subtract(candidate, available)).sign > 0 ? available : candidate
                balance = try subtract(balance, expense)
            }
        }
        return FinancialResult(try output(expense), planningAssumption("Declining-balance charge capped at remaining cost above salvage; factor " + factor.description + ", period " + String(period) + " of " + String(periods) +
            "; opening book value " + (try output(opening).display) + ", closing book value " + (try output(balance).display) + "; no automatic straight-line switch or final-year catch-up; no tax schedule inferred"))
    }
}
