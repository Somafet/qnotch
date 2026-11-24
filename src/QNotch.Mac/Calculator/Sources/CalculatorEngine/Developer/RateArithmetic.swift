import Foundation

extension Dimension {
    /// The C# record struct's ToString, which the rate traces print.
    var recordText: String {
        "Dimension { Length = \(length), Mass = \(mass), Time = \(time), Current = \(current), Temperature = \(temperature), Amount = \(amount), LuminousIntensity = \(luminousIntensity), Information = \(information) }"
    }
}

/// Transfer times, throughput, downtime budgets and usage counts/prices (C# RateArithmetic).
final class RateArithmetic {
    static let data = Dimension(0, 0, 0, 0, 0, 0, 0, 1)
    static let dataRate = Dimension(0, 0, -1, 0, 0, 0, 0, 1)
    static let inverseTime = Dimension(0, 0, -1, 0, 0, 0, 0, 0)
    static let convention = "Exact represented rates; SI/binary and bit/byte scales retained; ideal constant payload transfer or flat prorated supplied prices; no network, billing provider or availability measurement"
    /// Trace exact canonical magnitudes rather than rounded gutter text.
    static func evidence(_ value: SheetValue) throws -> String {
        switch value {
        case .usageCount(let count): return try count.details
        case .usagePrice(let price): return try price.details + stamp(price.amount)
        case .uptimeBudget(let budget): return try budget.details
        case .money(let money):
            return "Exact canonical money: " + (try money.magnitude.exact.text()) + " " + money.currency + "; dimension " + (money.magnitude.unit?.dimension.recordText ?? "dimensionless") + stamp(money)
        case .number(let number):
            return "Exact canonical magnitude: " + (try number.exact.text()) + "; dimension " + (number.unit?.dimension.recordText ?? "dimensionless")
        default: return try value.display
        }
    }
    private static func stamp(_ value: MoneyValue) -> String {
        value.rateStamp.map { "\nCurrency snapshot: " + $0.provider + "; " + $0.asOf.description + "; " + $0.key } ?? ""
    }
    static func isFunction(_ name: String) -> Bool {
        ["transfer", "throughput", "uptime", "downtime", "tokens", "requests", "items", "tokenprice", "requestprice", "itemprice", "usageprice", "usagecost", "usagefor"].contains(name.netLower)
    }
    static func validateArity(_ name: String, _ count: Int) throws {
        let valid: Bool
        switch name.netLower { case "tokens", "requests", "items": valid = count == 1; case "uptime": valid = count == 1 || count == 2; default: valid = count == 2 }
        if !valid { throw CalcError.format("\(name) has an invalid argument count") }
    }
    private let math: ExactArithmetic
    private let budget: ExecutionBudget
    private let token: CancellationToken
    private let money: MoneyArithmetic
    private let quantities: QuantityArithmetic
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic) {
        self.math = math; self.budget = budget; self.token = token; self.money = money; quantities = QuantityArithmetic(math)
    }
    private func step() throws { try budget.step(token) }
    private static func number(_ value: SheetValue) throws -> NumericValue {
        if case .integer(let integer) = value { return NumericValue(try Rational(integer.value)) }
        return try value.number
    }
    private static func plain(_ value: SheetValue) throws -> Rational {
        let n = try number(value)
        if n.unit != nil || !n.isRational || n.isPercentage || n.isApproximate { throw CalcError.arithmetic("Expected an exact dimensionless count") }
        return try n.exact.rational
    }
    @discardableResult
    private static func seconds(_ value: SheetValue, allowZero: Bool = false, requireExact: Bool = false) throws -> Rational {
        let n = try number(value)
        if n.unit?.dimension != TimeArithmetic.timeDimension || !n.isRational || requireExact && n.isApproximate || n.isPercentage ||
            n.exact.constant.numerator.sign < 0 || !allowZero && n.exact.constant.numerator.isZero {
            throw CalcError.arithmetic("Expected a positive exact elapsed duration; calendar months/years require an explicit elapsed interval")
        }
        return try n.exact.rational
    }
    private static func secondUnit() throws -> UnitExpression { try UnitExpression.single(UnitCatalog.byId("s")) }

    func count(_ value: SheetValue, _ kind: UsageKind) throws -> SheetValue { .usageCount(try UsageCountValue(try RateArithmetic.number(value), kind)) }
    func price(_ amount: SheetValue, _ perCount: Rational, _ kind: UsageKind?) throws -> SheetValue { .usagePrice(try UsagePriceValue(try amount.money, perCount, kind)) }
    func attach(_ count: UsageCountValue, _ unit: UnitExpression, _ conversion: Bool) throws -> SheetValue {
        .usageCount(try UsageCountValue(conversion ? try quantities.convert(count.quantity, unit) : try quantities.attach(count.quantity, unit), count.kind))
    }
    func convertCount(_ count: UsageCountValue, _ kind: UsageKind, _ unit: UnitExpression?) throws -> SheetValue {
        if count.kind != kind { throw CalcError.arithmetic("Cannot convert tokens to requests or generic items") }
        guard let unit else {
            if count.quantity.unit == nil { return .usageCount(count) }
            throw CalcError.arithmetic("Usage rate conversion requires /time")
        }
        return try attach(count, unit, true)
    }
    func nominal(_ budget: UptimeBudgetValue) throws -> SheetValue {
        let seconds = try RateArithmetic.secondUnit()
        return .number(NumericValue(try budget.downtimeSeconds).with { $0.unit = seconds; $0.useCompoundDuration = true; $0.useDaysInDuration = true })
    }
    func transfer(_ data: SheetValue, _ rate: SheetValue) throws -> SheetValue {
        try step(); let size = try RateArithmetic.number(data); let speed = try RateArithmetic.number(rate)
        if size.unit?.dimension != RateArithmetic.data || speed.unit?.dimension != RateArithmetic.dataRate || !size.isRational || !speed.isRational || size.isPercentage || speed.isPercentage ||
            size.exact.constant.numerator.sign < 0 || speed.exact.constant.numerator.sign <= 0 {
            throw CalcError.arithmetic("Transfer requires nonnegative data and a positive data/time speed")
        }
        let seconds = try RateArithmetic.secondUnit()
        return .number(try quantities.binary("/", size, speed).with { $0.unit = seconds; $0.useCompoundDuration = true; $0.useDaysInDuration = true })
    }
    func throughput(_ data: SheetValue, _ duration: SheetValue) throws -> SheetValue {
        try step(); let size = try RateArithmetic.number(data); try RateArithmetic.seconds(duration)
        if size.unit?.dimension != RateArithmetic.data || !size.isRational || size.isPercentage || size.exact.constant.numerator.sign < 0 { throw CalcError.arithmetic("Throughput requires nonnegative data") }
        let unit = try UnitExpression.single(UnitCatalog.byId("MB")).combine(try RateArithmetic.secondUnit(), -1)
        return .number(try quantities.convert(try quantities.binary("/", size, try RateArithmetic.number(duration)), unit).with { $0.displayDecimalPlaces = 2 })
    }
    func at(_ subject: SheetValue, _ price: SheetValue) throws -> SheetValue {
        try step()
        if case .usagePrice(let p) = price {
            let count: UsageCountValue
            if case .usageCount(let c) = subject { count = c } else { count = try UsageCountValue(try RateArithmetic.number(subject), .items) }
            if let kind = p.kind, kind != count.kind { throw CalcError.arithmetic("Usage kind does not match the price denominator") }
            let quantity = try quantities.scale(count.quantity, try Rational.one / p.perCount)
            let result = try money.binary("*", .money(p.amount), .number(quantity)).money
            return .money(try MoneyValue(result.magnitude, result.currency, result.rateStamp))
        }
        if case .number(let s) = subject, case .number(let r) = price, s.unit?.dimension == RateArithmetic.data, r.unit?.dimension == RateArithmetic.dataRate { return try transfer(subject, price) }
        if subject.kind == .number, case .money(let p) = price, p.magnitude.unit != nil {
            let amount = try RateArithmetic.number(subject)
            if try math.sign(amount.exact) < 0 || math.sign(p.magnitude.exact) < 0 { throw CalcError.arithmetic("Flat billing inputs cannot be negative") }
            let result = try money.binary("*", price, subject).money
            if result.magnitude.unit != nil { throw CalcError.arithmetic("Price denominator does not cancel the supplied quantity") }
            return .money(try MoneyValue(result.magnitude, result.currency, result.rateStamp))
        }
        throw CalcError.arithmetic("Expected data at a transfer speed, or a count/quantity at its unit price")
    }
    /// C# For: a rate over an elapsed duration.
    func forDuration(_ rate: SheetValue, _ duration: SheetValue) throws -> SheetValue {
        try step(); try RateArithmetic.seconds(duration, allowZero: true)
        if case .money(let m) = rate, m.magnitude.unit?.dimension == RateArithmetic.inverseTime {
            if try math.sign(m.magnitude.exact) < 0 { throw CalcError.arithmetic("Billing rate cannot be negative") }
            let result = try money.binary("*", rate, duration).money; return .money(try MoneyValue(result.magnitude, result.currency, result.rateStamp))
        }
        if case .usageCount(let c) = rate, c.quantity.unit?.dimension == RateArithmetic.inverseTime { return try binary("*", rate, duration) }
        if case .number(let r) = rate, r.unit?.dimension == RateArithmetic.dataRate {
            if !r.isRational || r.exact.constant.numerator.sign < 0 { throw CalcError.arithmetic("Data rate must be nonnegative rational") }
            return .number(try quantities.binary("*", r, try RateArithmetic.number(duration)))
        }
        throw CalcError.arithmetic("for requires an elapsed-time rate; calendar earnings are separate")
    }
    func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue {
        try step()
        if left.kind == .money, case .usagePrice(let p) = right, operation == "/" {
            let ratio = try money.binary("/", left, .money(p.amount))
            return .usageCount(try UsageCountValue(try quantities.scale(try ratio.number, p.perCount), p.kind ?? .items))
        }
        if case .usagePrice(let a) = left, case .usagePrice(let b) = right {
            if a.kind != b.kind { throw CalcError.arithmetic("Price kinds must match") }
            let normalized = try MoneyValue(try quantities.scale(b.amount.magnitude, try a.perCount / b.perCount), b.amount.currency, b.amount.rateStamp)
            if operation != "+" && operation != "-" { throw CalcError.arithmetic("Unit prices support matching addition/subtraction or numeric scaling") }
            return .usagePrice(try UsagePriceValue(try money.binary(operation, .money(a.amount), .money(normalized)).money, a.perCount, a.kind))
        }
        if left.kind == .usagePrice || right.kind == .usagePrice {
            let price = left.kind == .usagePrice ? try left.usagePrice : try right.usagePrice; let other = left.kind == .usagePrice ? right : left
            if other.kind == .usageCount && (operation == "*" || operation == "of") { return try at(other, .usagePrice(price)) }
            if (other.kind == .number || other.kind == .integer) && ["*", "/", "of"].contains(operation) && (operation != "/" || left.kind == .usagePrice) {
                let n = try RateArithmetic.number(other)
                if n.unit != nil || n.isPercentage { throw CalcError.arithmetic("Unit-price scaling requires an ordinary scalar") }
                return .usagePrice(try UsagePriceValue(try money.binary(operation, .money(price.amount), .number(n)).money, price.perCount, price.kind))
            }
            throw CalcError.arithmetic("Unsupported unit-price arithmetic")
        }
        if case .usageCount(let a) = left, case .usageCount(let b) = right {
            if a.kind != b.kind { throw CalcError.arithmetic("Cannot mix token and request counts") }
            let result = try quantities.binary(operation, a.quantity, b.quantity)
            if operation == "/" { return .number(result) }
            if operation == "+" || operation == "-" { return .usageCount(try UsageCountValue(result, a.kind)) }
            throw CalcError.arithmetic("Products of counts are unsupported")
        }
        if left.kind != .usageCount && right.kind != .usageCount { throw CalcError.arithmetic("Unsupported unit-price arithmetic") }
        let count = left.kind == .usageCount ? try left.usageCount : try right.usageCount
        let numeric = try RateArithmetic.number(left.kind == .usageCount ? right : left)
        if numeric.isPercentage && (operation == "+" || operation == "-") && left.kind == .usageCount {
            return .usageCount(try UsageCountValue(try quantities.binary(operation, count.quantity, numeric), count.kind))
        }
        if !["*", "/", "of"].contains(operation) || operation == "/" && left.kind != .usageCount { throw CalcError.arithmetic("Counts require matching counts or numeric scaling") }
        return .usageCount(try UsageCountValue(try quantities.binary(operation, count.quantity, numeric), count.kind))
    }
    func unary(_ operation: String, _ value: SheetValue) throws -> SheetValue {
        if operation != "+" && operation != "-" { throw CalcError.arithmetic("Unsupported count/price unary operation") }
        if case .usageCount(let count) = value { return .usageCount(try UsageCountValue(try quantities.unary(operation, count.quantity), count.kind)) }
        let p = try value.usagePrice; return .usagePrice(try UsagePriceValue(try money.unary(operation, p.amount), p.perCount, p.kind))
    }
    func aggregate(_ values: [SheetValue], _ average: Bool) throws -> SheetValue {
        guard var sum = values.first else { throw CalcError.arithmetic("No usage values to aggregate") }
        for value in values.dropFirst() { sum = try binary("+", sum, value) }
        return average ? try binary("/", sum, SheetValue(Rational(values.count))) : sum
    }
    func round(_ kind: RoundingKind, _ value: SheetValue, _ precision: SheetValue) throws -> SheetValue {
        if case .usageCount(let count) = value {
            let quantum: NumericValue
            if case .usageCount(let p) = precision {
                if p.kind != count.kind { throw CalcError.arithmetic("Count rounding kind mismatch") }
                quantum = p.quantity
            } else { quantum = try RateArithmetic.number(precision) }
            return .usageCount(try UsageCountValue(try quantities.round(kind, count.quantity, quantum, token), count.kind))
        }
        let p = try value.usagePrice; return .usagePrice(try UsagePriceValue(try money.round(kind, p.amount, precision, token), p.perCount, p.kind))
    }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue {
        try step(); try RateArithmetic.validateArity(name, args.count); let key = name.netLower
        if key == "tokens" || key == "requests" || key == "items" { return try count(args[0], key == "tokens" ? .tokens : key == "requests" ? .requests : .items) }
        if key.hasSuffix("price") {
            return try price(args[0], try RateArithmetic.plain(args[1]), key == "tokenprice" ? .tokens : key == "requestprice" ? .requests : key == "itemprice" ? .items : nil)
        }
        if key == "transfer" { return try transfer(args[0], args[1]) }
        if key == "throughput" { return try throughput(args[0], args[1]) }
        if key == "usagecost" { return try at(args[0], args[1]) }
        if key == "usagefor" { return try forDuration(args[0], args[1]) }
        let availability = try RateArithmetic.number(args[0])
        if !availability.isPercentage || !availability.isRational || availability.isApproximate { throw CalcError.arithmetic("Uptime target requires an exact percentage") }
        let defaultInterval = args.count == 1
        // The default interval is a mean month: 365.25 days / 12.
        let seconds = defaultInterval ? try Rational(BigInt(36525 * 86400), BigInt(1200)) : try RateArithmetic.seconds(args[1], requireExact: true)
        return .uptimeBudget(try UptimeBudgetValue(try availability.exact.rational, seconds, defaultInterval))
    }
}
