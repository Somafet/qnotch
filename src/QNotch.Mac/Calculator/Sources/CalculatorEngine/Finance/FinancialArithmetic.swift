import Foundation

/// One annual row of an amortization schedule.
struct AmortizationYear: Hashable {
    let year: Int, payments: Int
    let interest: SheetValue, principal: SheetValue, balance: SheetValue
    init(_ year: Int, _ payments: Int, _ interest: SheetValue, _ principal: SheetValue, _ balance: SheetValue) {
        self.year = year; self.payments = payments; self.interest = interest; self.principal = principal; self.balance = balance
    }
}

/// C# FinancialResult: a value, its assumption text and optional evidence for the explanation step.
struct FinancialResult {
    var value: SheetValue
    var assumption: String
    var schedule: [AmortizationYear]?
    var irr: IrrEvidence?
    var growth: GrowthEvidence?
    init(_ value: SheetValue, _ assumption: String, _ schedule: [AmortizationYear]? = nil, irr: IrrEvidence? = nil, growth: GrowthEvidence? = nil) {
        self.value = value; self.assumption = assumption; self.schedule = schedule; self.irr = irr; self.growth = growth
    }
}

/// Bounded financial models. Exact fractions first; explicitly marked 34-significant-digit fallback.
/// The planning functions live in FinancialPlanning.swift and late fees/invoices in InvoiceArithmetic.swift.
final class FinancialArithmetic {
    static let maxPeriods = 1200
    let budget: ExecutionBudget, token: CancellationToken, money: MoneyArithmetic
    /// Set once any input was approximate or an intermediate result needed the 34-digit fallback.
    var approximate = false
    /// The first monetary input: every cash flow converts to its currency and every output carries it.
    var template: MoneyValue?
    init(_ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic) { self.budget = budget; self.token = token; self.money = money }

    static func isFunction(_ name: String) -> Bool { isPlanningFunction(name) || ["pmt", "fv", "pv", "npv", "irr"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        if isPlanningFunction(name) { try validatePlanningArity(name, count); return }
        if name.equalsIgnoreCase("irr") {
            if count < 1 || count > 16 { throw CalcError.format("irr expects scalar cash flows or a list with an optional guess") }
            return
        }
        let minimum = name.equalsIgnoreCase("npv") ? 2 : 3
        let maximum = minimum == 2 ? 16 : 5
        if count < minimum || count > maximum { throw CalcError.format("\(name) expects \(minimum)–\(maximum) arguments") }
    }

    // MARK: Bounded rational arithmetic

    /// Reduces n/d; above 4096 bits, rounds half away from zero to 34 significant digits and marks the result approximate.
    func normalize(_ numerator: BigInt, _ denominator: BigInt) throws -> Rational {
        try budget.step(token)
        if denominator.isZero { throw CalcError.arithmetic("Undefined financial result; zero divisor") }
        var numerator = numerator, denominator = denominator
        if denominator.sign < 0 { numerator = -numerator; denominator = -denominator }
        let common = BigInt.gcd(numerator, denominator)
        numerator = numerator / common; denominator = denominator / common
        if numerator.bitLength <= 4096 && denominator.bitLength <= 4096 { return try Rational(numerator, denominator) }
        approximate = true
        // Inputs have bounded components; temporary products have at most 8193 bits.
        // Round only on overflow. No logarithms, doubles, unbounded precision or silent zero underflow.
        let magnitude = numerator.magnitude
        var exponent = magnitude.description.netLength - denominator.description.netLength
        if exponent >= 0 ? magnitude < denominator * BigInt.pow(10, exponent) : magnitude * BigInt.pow(10, -exponent) < denominator { exponent -= 1 }
        let places = 33 - exponent
        if Swift.abs(places) > 1233 { throw CalcError.arithmetic("Financial precision limit exceeded") }
        let quantum = BigInt.pow(10, Swift.abs(places))
        let scaledNumerator = places >= 0 ? magnitude * quantum : magnitude
        let scaledDenominator = places >= 0 ? denominator : denominator * quantum
        let division = scaledNumerator.quotientAndRemainder(dividingBy: scaledDenominator)
        var whole = division.quotient
        if division.remainder * 2 >= scaledDenominator { whole += 1 }
        let signed = BigInt(numerator.sign) * whole
        return places >= 0 ? try Rational(signed, quantum) : try Rational(signed * quantum, .one)
    }
    func add(_ a: Rational, _ b: Rational) throws -> Rational { try normalize(a.numerator * b.denominator + b.numerator * a.denominator, a.denominator * b.denominator) }
    func negate(_ a: Rational) -> Rational { -a }
    func subtract(_ a: Rational, _ b: Rational) throws -> Rational { try add(a, negate(b)) }
    func multiply(_ a: Rational, _ b: Rational) throws -> Rational { try normalize(a.numerator * b.numerator, a.denominator * b.denominator) }
    func divide(_ a: Rational, _ b: Rational) throws -> Rational { try normalize(a.numerator * b.denominator, a.denominator * b.numerator) }

    // MARK: Inputs and outputs

    func plain(_ value: SheetValue, _ percentage: Bool = false) throws -> Rational {
        let number = try value.number
        if !number.isRational || number.unit != nil || !percentage && number.isPercentage {
            throw CalcError.arithmetic("Financial inputs require rational scalars or monetary amounts")
        }
        approximate = approximate || number.isApproximate
        return try number.scalar
    }
    func rate(_ value: SheetValue) throws -> Rational {
        let rate = try plain(value, true)
        if rate.numerator <= -rate.denominator { throw CalcError.arithmetic("Financial rate must be greater than -100% per stated period") }
        return rate
    }
    func periods(_ value: SheetValue, _ allowZero: Bool) throws -> Int {
        let count = try plain(value)
        if try value.number.isApproximate || !count.denominator.isOne || count.numerator < BigInt(allowZero ? 0 : 1) || count.numerator > BigInt(FinancialArithmetic.maxPeriods) {
            throw CalcError.arithmetic("Financial periods must be an exact integer from \(allowZero ? 0 : 1) to \(FinancialArithmetic.maxPeriods)")
        }
        return count.numerator.intValue!
    }
    func setTemplate(_ cash: [SheetValue]) throws {
        template = nil
        for value in cash where value.kind == .money { template = try value.money; break }
    }
    func cash(_ value: SheetValue) throws -> Rational {
        if value.kind != .money {
            let scalar = try plain(value)
            if template != nil && !scalar.isZero { throw CalcError.arithmetic("Do not mix bare and currency cash flows; only bare zero is currency-neutral") }
            return scalar
        }
        // setTemplate always ran over the monetary inputs first, so a template exists here (C# dereferences it).
        guard let current = template else { throw CalcError.arithmetic("Expected a monetary first argument") }
        let converted = try money.convert(try value.money, current.currency)
        if current.rateStamp != nil && converted.rateStamp != nil && current.rateSnapshotKey != converted.rateSnapshotKey {
            throw CalcError.arithmetic("Financial cash flows use different currency snapshots")
        }
        template = try MoneyValue(current.magnitude, current.currency, current.rateStamp ?? converted.rateStamp)
        return try plain(.number(converted.magnitude))
    }
    func output(_ amount: Rational) throws -> SheetValue {
        let number = NumericValue(amount).with { $0.isApproximate = approximate; $0.displayDecimalPlaces = 4 }
        guard let template else { return .number(number) }
        return .money(try MoneyValue(number, template.currency, template.rateStamp))
    }
    /// (1+rate)^periods and the annuity factor sum((1+rate)^k, k < periods), by binary splitting.
    func series(_ rate: Rational, _ periods: Int) throws -> (growth: Rational, annuity: Rational) {
        try budget.step(token)
        if periods == 0 { return (.one, .zero) }
        let (growth, annuity) = try series(rate, periods / 2)
        let doubledAnnuity = try multiply(annuity, try add(.one, growth))
        let doubledGrowth = try multiply(growth, growth)
        return periods % 2 == 0 ? (doubledGrowth, doubledAnnuity) :
            (try multiply(doubledGrowth, try add(.one, rate)), try add(doubledAnnuity, doubledGrowth))
    }
    private func assumption(_ detail: String) -> String {
        detail + "; constant rate and equal periods; no taxes, fees, insurance or changing returns; source amounts retained; display rounding is not payment settlement" +
            (approximate ? "; ≈ bounded arithmetic rounded to 34 significant digits when exact components exceeded 4096 bits, or an input was already approximate; not a certified error interval" : "; exact rational computation") +
            (money.provenance.map { "; " + $0 } ?? "")
    }
    /// C# StatisticsArithmetic.Flatten (math area): list arguments contribute their items; only numbers and money pass.
    static func flatten(_ arguments: [SheetValue], _ budget: ExecutionBudget, _ token: CancellationToken) throws -> [SheetValue] {
        var values: [SheetValue] = []
        func add(_ value: SheetValue) throws {
            try budget.step(token)
            if values.count == SheetList.maxItems { throw CalcError.arithmetic("Combined list exceeds 1024 values") }
            if value.kind != .number && value.kind != .money { throw CalcError.arithmetic("Statistics and cash flows require numeric or monetary values") }
            values.append(value)
        }
        for argument in arguments {
            if case .list(let list) = argument { for item in list.values { try add(item) } } else { try add(argument) }
        }
        return values
    }

    // MARK: pmt, fv, pv, npv, irr

    func function(_ name: String, _ args: [SheetValue]) throws -> FinancialResult {
        try FinancialArithmetic.validateArity(name, args.count)
        if FinancialArithmetic.isPlanningFunction(name) { return try planningFunction(name, args) }
        if name.equalsIgnoreCase("irr") { return try irr(args) }
        let key = name.netLower; let rate = try self.rate(args[0])
        if key == "npv" {
            let flows = try FinancialArithmetic.flatten(Array(args.dropFirst()), budget, token)
            if flows.isEmpty { throw CalcError.arithmetic("NPV requires at least one cash flow") }
            try setTemplate(flows); let cash = try flows.map { try self.cash($0) }; var result = Rational.zero
            for i in stride(from: cash.count - 1, through: 0, by: -1) { result = try divide(try add(result, cash[i]), try add(.one, rate)) }
            return FinancialResult(try output(result), assumption("NPV: first cash flow at period 1; signed incoming/outgoing cash flows; add time-zero investment separately"))
        }
        let n = try periods(args[1], key != "pmt")
        let timing = args.count == 5 ? try periods(args[4], true) : 0
        if timing > 1 { throw CalcError.arithmetic("Financial payment timing must be 0 (end) or 1 (beginning)") }
        try setTemplate(Array(args.dropFirst(2).prefix(min(2, args.count - 2))))
        let a = try cash(args[2]); let b = args.count >= 4 ? try cash(args[3]) : .zero
        var (growth, annuity) = try series(rate, n)
        if timing == 1 { annuity = try multiply(annuity, try add(.one, rate)) }
        let answer: Rational
        switch key {
        case "pmt": answer = try divide(try add(try multiply(a, growth), b), annuity)
        case "fv": answer = negate(try add(try multiply(b, growth), try multiply(a, annuity)))
        case "pv": answer = try divide(negate(try add(b, try multiply(a, annuity))), growth)
        default: throw CalcError.format("Unknown financial function")
        }
        let detail = key == "pmt" ? "PMT: positive payment for positive borrowed principal (opposite Excel PMT sign); pv*growth - payment*annuity + fv = 0" :
            key == "fv" ? "FV: signed cash flows; -(pv*growth + payment*annuity)" : "PV: signed cash flows; -(fv + payment*annuity)/growth"
        return FinancialResult(try output(answer), assumption(detail + "; rate is per period; " + String(n) + " periods; payments at " + (timing == 0 ? "end" : "beginning")))
    }
    private func irr(_ args: [SheetValue]) throws -> FinancialResult {
        let flows: [SheetValue]; var guess = try Rational(1, 10)
        if args[0].kind == .list {
            if args.count > 2 { throw CalcError.format("IRR list form is irr(cashFlows[,guess])") }
            flows = try FinancialArithmetic.flatten(Array(args.prefix(1)), budget, token)
            if args.count == 2 { guess = try rate(args[1]) }
        } else {
            if args.contains(where: { $0.kind == .list }) { throw CalcError.format("Use irr(cashFlows[,guess]) for list inputs") }
            flows = try FinancialArithmetic.flatten(args, budget, token)
        }
        try setTemplate(flows); let cash = try flows.map { try self.cash($0) }
        let solution = try IrrSolver(budget, token).solve(cash, guess)
        var evidence = solution.evidence; evidence.inputApproximate = approximate
        let selected = evidence.roots[evidence.selectedRoot]
        let output = NumericValue(solution.rate, isPercentage: true).with { $0.isApproximate = approximate || !selected.exact; $0.displayDecimalPlaces = 4 }
        func percent(_ rate: Rational) throws -> String { try NumericValue(rate, isPercentage: true).with { $0.displayDecimalPlaces = 4 }.display }
        let candidates = try evidence.roots.prefix(8).map { try percent(try FinancialArithmetic.fractionMidpoint($0.lowerRate, $0.upperRate)) }.joined(separator: ", ")
        let assumption = "IRR: first cash flow at time 0, equal intervals, result per interval (not automatically annualized); " + String(flows.count) + " ordered flows; " +
            String(evidence.distinctRoots) + " distinct admissible rate(s) > -100%, repeated roots counted once; " + evidence.method +
            "; candidates " + candidates + (evidence.roots.count > 8 ? ", …" : "") + "; nearest supplied/default guess " + (try percent(guess)) +
            "; within relative distance tolerance 1e-12, lower rate wins" + (evidence.toleranceTie ? "; tolerance tie applied" : "") +
            "; selected root has " + (selected.exact ? "an exact rational substitution" : "a certified rate enclosure with relative width <= 1e-14 (absolute near zero) and stable four-decimal percentage display") +
            (approximate ? "; certificate concerns represented inputs; upstream amount/guess approximation remains" : "; exact represented cash flows") +
            (money.provenance.map { "; " + $0 } ?? "")
        return FinancialResult(.number(output), assumption, irr: evidence)
    }
    private static func fractionMidpoint(_ a: Rational, _ b: Rational) throws -> Rational {
        let n = a.numerator * b.denominator + b.numerator * a.denominator, d = 2 * a.denominator * b.denominator
        let common = BigInt.gcd(n, d); return try Rational(n / common, d / common)
    }

    // MARK: loan, mortgage, amortize, save, grow

    func plan(_ expression: FinancialPlanExpression, _ args: [SheetValue]) throws -> FinancialResult {
        try setTemplate([args[0]] + args.dropFirst(3).filter { !$0.isPercentage })
        var amount = try cash(args[0])
        if amount.sign < 0 { throw CalcError.arithmetic("Loan, investment and contribution amounts must be nonnegative") }
        let annualRate = try self.rate(args[1])
        guard case .calendarPeriod(let term) = args[2], term.days == 0, term.months >= 1, term.months <= FinancialArithmetic.maxPeriods else {
            throw CalcError.arithmetic("Financial term must contain 1–1200 whole calendar months")
        }
        let isLoan = expression.kind == "loan" || expression.kind == "mortgage" || expression.kind == "amortize"
        let monthly = isLoan || expression.frequency == 12
        if !monthly && term.months % 12 != 0 { throw CalcError.arithmetic("Annual compounding requires whole years; use compounded monthly for a monthly term") }
        let frequency = monthly ? 12 : 1
        let n = term.months / (12 / frequency); let rate = try divide(annualRate, Rational(frequency))
        if args.count == 4 {
            let down = args[3].isPercentage ? try multiply(amount, try plain(args[3], true)) : try cash(args[3])
            if try down.sign < 0 || subtract(amount, down).sign < 0 { throw CalcError.arithmetic("Down payment must be between zero and the purchase price") }
            amount = try subtract(amount, down)
        }
        let (growth, annuity) = try series(rate, n)
        if isLoan {
            let payment = try divide(try multiply(amount, growth), annuity)
            let total = try multiply(payment, Rational(n)); let interest = try subtract(total, amount)
            var rows: [AmortizationYear] = []
            if expression.kind == "amortize" {
                var previous = amount
                for paid in stride(from: 0, to: n, by: 12) {
                    let count = min(12, n - paid); let end = paid + count
                    let remaining = try series(rate, n - end); let elapsed = try series(rate, end)
                    let balance = try divide(try multiply(try multiply(amount, elapsed.growth), remaining.annuity), annuity)
                    let principal = try subtract(previous, balance)
                    rows.append(AmortizationYear(rows.count + 1, count, try output(try subtract(try multiply(payment, Rational(count)), principal)), try output(principal), try output(balance)))
                    previous = balance
                }
            }
            // A later schedule row may activate fallback; mark every output consistently.
            if approximate { rows = try rows.map { AmortizationYear($0.year, $0.payments, try FinancialArithmetic.mark($0.interest), try FinancialArithmetic.mark($0.principal), try FinancialArithmetic.mark($0.balance)) } }
            let value = try output(payment)
            let detail = "Monthly end-of-period payment; nominal annual rate / 12; " + String(n) + " payments; borrowed " + (try output(amount).display) +
                "; total paid " + (try output(total).display) + "; total interest " + (try output(interest).display) + "; annual rows cover 12 payments, final row may be shorter"
            return FinancialResult(value, assumption(detail), rows)
        }
        let result = try multiply(amount, expression.kind == "save" ? annuity : growth)
        let contributed = expression.kind == "save" ? try multiply(amount, Rational(n)) : amount
        let addedGrowth = try subtract(result, contributed)
        let value = try output(result)
        let detail = (expression.kind == "save" ? "End-of-period contributions" : "Lump-sum growth") + "; nominal annual rate / " + String(frequency) +
            "; " + String(n) + " periods; contributed " + (try output(contributed).display) + "; growth " + (try output(addedGrowth).display)
        return FinancialResult(value, assumption(detail))
    }
    private static func mark(_ value: SheetValue) throws -> SheetValue {
        if case .money(let money) = value { return .money(try MoneyValue(money.magnitude.with { $0.isApproximate = true }, money.currency, money.rateStamp)) }
        return .number(try value.number.with { $0.isApproximate = true })
    }
}
