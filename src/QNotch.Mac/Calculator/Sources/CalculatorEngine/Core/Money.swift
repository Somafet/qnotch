import Foundation
import CryptoKit

/// C# `Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)))`: uppercase hex.
func sha256Hex(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined() }

extension Instant {
    /// DateTimeOffset.ToString("O") in UTC: 2026-10-30T12:00:00.0000000+00:00.
    var roundTrip: String {
        let local = NetDateTime(ticks: unixTicks + Ticks.unixEpoch)
        return local.date.description + "T" + local.timeOfDay.hhmmss + "." + pad(local.timeOfDay.fraction, 7) + "+00:00"
    }
    /// `new DateTimeOffset(y, m, d, h, mi, s, TimeSpan.Zero)`.
    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Instant {
        Instant(unixTicks: Int64(DateOnly(year, month, day)!.dayNumber) * Ticks.perDay + Int64(hour) * Ticks.perHour + Int64(minute) * Ticks.perMinute + Int64(second) * Ticks.perSecond - Ticks.unixEpoch)
    }
}

struct CurrencyRateStamp: Hashable { let key: String, provider: String, asOf: DateOnly, retrievedAt: Instant }

/// Exact monetary quantity. Decimal display rounding never replaces its authoritative magnitude.
final class MoneyValue: Hashable {
    let magnitude: NumericValue
    let currency: String
    let rateStamp: CurrencyRateStamp?
    let exactDisplay: Bool
    var rateSnapshotKey: String? { rateStamp?.key }
    init(_ magnitude: NumericValue, _ currency: String, _ provenance: CurrencyRateStamp? = nil, _ exactDisplay: Bool = false) throws {
        if magnitude.isPercentage || magnitude.unit?.isTemperaturePoint == true { throw CalcError.arithmetic("Invalid money magnitude") }
        self.currency = try CurrencyCatalog.byCode(currency).code; self.magnitude = magnitude
        if let provenance, provenance.key.netLength > 64 { throw CalcError.arithmetic("Invalid currency provenance") }
        rateStamp = provenance; self.exactDisplay = exactDisplay
    }
    var display: String {
        get throws {
            let math = ExactArithmetic(ExecutionBudget(), .none); let quantities = QuantityArithmetic(math)
            let displayed = try quantities.displayMagnitude(magnitude)
            let rounded = try ExactRounding.apply(.decimalPlaces, NumericValue(displayed), NumericValue(Rational(try CurrencyCatalog.byCode(currency).digits)), .none, math)
            var number = exactDisplay ? try displayed.text() : try rounded.display
            if exactDisplay && (!displayed.isRational || number.contains("/")) { number = "(" + number + ")" }
            let text = (magnitude.isApproximate ? "≈ " : "") + number + " " + currency + (magnitude.unit?.moneySuffix() ?? "")
            if text.netLength > 2048 { throw CalcError.arithmetic("Money output limit exceeded") }
            return text
        }
    }
    static func == (a: MoneyValue, b: MoneyValue) -> Bool { a.magnitude == b.magnitude && a.currency == b.currency && a.rateStamp == b.rateStamp && a.exactDisplay == b.exactDisplay }
    func hash(into hasher: inout Hasher) { hasher.combine(magnitude); hasher.combine(currency) }
}

final class CurrencyRateSnapshot {
    static let maxCurrencies = 256
    /// Provider identity of the European Commission's monthly InforEuro accounting rates.
    static let monthlyEuProvider = "EC InforEuro via Frankfurter"
    var isMonthly: Bool { provider == CurrencyRateSnapshot.monthlyEuProvider }
    let provider: String, baseCurrency: String
    let asOf: DateOnly
    let retrievedAt: Instant
    let rates: [String: Rational]
    let key: String
    init(provider: String, baseCurrency: String, asOf: DateOnly, retrievedAt: Instant, rates: [(String, Rational)]) throws {
        if provider.netLength < 1 || provider.netLength > 80 || !CurrencyCatalog.validCode(baseCurrency) { throw CalcError.arithmetic("Invalid currency snapshot identity") }
        self.provider = provider; self.baseCurrency = baseCurrency; self.asOf = asOf; self.retrievedAt = retrievedAt
        var copies: [String: Rational] = [:]
        for (code, rate) in rates {
            if copies.count >= CurrencyRateSnapshot.maxCurrencies || !CurrencyCatalog.validCode(code) || rate.numerator.sign <= 0 || rate.numerator.bitLength > 256 || rate.denominator.bitLength > 256 || copies[code] != nil {
                throw CalcError.arithmetic("Invalid or oversized currency rate snapshot")
            }
            copies[code] = rate
        }
        guard let identity = copies[baseCurrency], identity == .one else { throw CalcError.arithmetic("Currency base rate must be one") }
        self.rates = copies
        key = sha256Hex(provider + ":" + baseCurrency + ":" + asOf.description + ":" +
            copies.keys.sorted { String.ordinalCompare($0, $1) < 0 }.map { $0 + "=" + copies[$0]!.description }.joined(separator: ";"))
    }
    func crossRate(_ from: String, _ to: String) throws -> Rational {
        guard let a = rates[from], let b = rates[to] else { throw CalcError.arithmetic("Currency rate unavailable: \(from) to \(to)") }
        return try b / a
    }
}

final class CurrencyRateBook {
    static let maxHistoricalSnapshots = 64
    static let empty = try! CurrencyRateBook(nil, [])
    let latest: CurrencyRateSnapshot?
    let historical: [DateOnly: CurrencyRateSnapshot]
    let key: String
    init(_ latest: CurrencyRateSnapshot?, _ historical: [(DateOnly, CurrencyRateSnapshot)]) throws {
        self.latest = latest; var copies: [DateOnly: CurrencyRateSnapshot] = [:]
        for (date, snapshot) in historical {
            if copies.count >= CurrencyRateBook.maxHistoricalSnapshots || snapshot.asOf > date || date.dayNumber - snapshot.asOf.dayNumber > 10 || copies[date] != nil {
                throw CalcError.arithmetic("Invalid historical currency snapshot")
            }
            copies[date] = snapshot
        }
        self.historical = copies
        key = (latest?.key ?? "none") + ":" + (latest?.retrievedAt.roundTrip ?? "") + ":" +
            copies.keys.sorted().map { String($0.dayNumber) + "=" + copies[$0]!.key + ":" + copies[$0]!.retrievedAt.roundTrip }.joined(separator: ";")
    }
    func require(_ requested: DateOnly?) throws -> CurrencyRateSnapshot {
        guard let requested else {
            guard let latest else { throw CalcError.arithmetic("Daily currency rates unavailable; download rates explicitly") }
            return latest
        }
        guard let value = historical[requested] else { throw CalcError.arithmetic("Historical currency rates unavailable for \(requested)") }
        return value
    }
}

struct CurrencyRateRequest: Hashable { let date: DateOnly? }

final class MoneyArithmetic {
    let math: ExactArithmetic, context: EvaluationContext, reads: ContextReads
    private let quantities: QuantityArithmetic
    private(set) var provenance: String?
    init(_ math: ExactArithmetic, _ context: EvaluationContext, _ reads: ContextReads) { self.math = math; self.context = context; self.reads = reads; quantities = QuantityArithmetic(math) }
    private func snapshot() throws -> CurrencyRateSnapshot {
        reads.dependencies.formUnion([.currencyRates, .date])
        reads.currencyRequests.insert(DateOnlyKey(date: context.currencyDate))
        if reads.currencyRequests.count > CurrencyRateBook.maxHistoricalSnapshots + 1 { throw CalcError.arithmetic("Currency request limit exceeded") }
        if let requestedDate = context.currencyDate, let currentDate = context.today, requestedDate > currentDate { throw CalcError.arithmetic("Future historical currency rates are unavailable") }
        let snapshot = try (context.currencyRates ?? CurrencyRateBook.empty).require(context.currencyDate)
        if context.currencyDate == nil, let nowDate = context.today, snapshot.asOf > nowDate { throw CalcError.arithmetic("Currency snapshot is dated after the current context date") }
        let age = context.today.map { $0.dayNumber - snapshot.asOf.dayNumber }
        let monthly = snapshot.isMonthly
        var text = snapshot.provider + (monthly ? "; cached monthly accounting rates for the month from " : "; cached daily reference rates as of ") + snapshot.asOf.description + "; retrieved " + snapshot.retrievedAt.roundTrip
        if let requested = context.currencyDate {
            text += "; requested " + requested.description + (requested == snapshot.asOf ? "" : monthly ? "; monthly rate in force" : "; previous published business date")
        } else if let age {
            text += age > (monthly ? 35 : 3) ? "; STALE" : monthly ? "; monthly data, not live" : "; daily data, not live"
        } else { text += "; age unavailable" }
        provenance = text + "; exact cross-rate arithmetic; displayed amounts rounded, source values retained"
        return snapshot
    }
    private static func merge(_ a: MoneyValue, _ b: MoneyValue) throws -> CurrencyRateStamp? {
        if let x = a.rateSnapshotKey, let y = b.rateSnapshotKey, x != y { throw CalcError.arithmetic("Monetary values use different rate snapshots; evaluate them under one date") }
        return a.rateStamp ?? b.rateStamp
    }
    func attach(_ value: SheetValue, _ currency: String) throws -> MoneyValue { try MoneyValue(try value.number, currency) }
    func convert(_ value: MoneyValue, _ currency: String, _ unit: UnitExpression? = nil) throws -> MoneyValue {
        var amount = value.magnitude; var provenance = value.rateStamp
        if currency != value.currency || context.currencyDate != nil && provenance != nil {
            let snapshot = try self.snapshot()
            if let provenance, provenance.key != snapshot.key { throw CalcError.arithmetic("Monetary value was converted with another rate date; put the original expression inside the dated conversion") }
            amount = try quantities.scale(amount, snapshot.crossRate(value.currency, currency))
            provenance = CurrencyRateStamp(key: snapshot.key, provider: snapshot.provider, asOf: snapshot.asOf, retrievedAt: snapshot.retrievedAt)
        }
        if let unit { amount = try quantities.convert(amount, unit) }
        return try MoneyValue(amount, currency, provenance, value.exactDisplay)
    }
    func attachUnit(_ value: MoneyValue, _ unit: UnitExpression) throws -> MoneyValue {
        try MoneyValue(try quantities.binary("*", value.magnitude, quantities.attach(NumericValue(Rational.one), unit)), value.currency, value.rateStamp, value.exactDisplay)
    }
    func convertUnit(_ value: MoneyValue, _ unit: UnitExpression) throws -> MoneyValue {
        try MoneyValue(try quantities.convert(value.magnitude, unit), value.currency, value.rateStamp, value.exactDisplay)
    }
    func unary(_ operation: String, _ value: MoneyValue) throws -> MoneyValue {
        if operation != "+" && operation != "-" { throw CalcError.arithmetic("Money cannot use a percentage, factorial or other numeric unary operator") }
        return try MoneyValue(try quantities.unary(operation, value.magnitude), value.currency, value.rateStamp, value.exactDisplay)
    }
    func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue {
        if left.kind == .money && right.kind == .money {
            let a = try left.money; let b = try convert(try right.money, a.currency); let provenance = try MoneyArithmetic.merge(a, b)
            if operation == "+" || operation == "-" { return .money(try MoneyValue(try quantities.binary(operation, a.magnitude, b.magnitude), a.currency, provenance, a.exactDisplay || b.exactDisplay)) }
            if operation == "/" { return .number(try quantities.binary(operation, a.magnitude, b.magnitude)) }
            throw CalcError.arithmetic("Money products/powers are not supported; divide monetary quantities for a ratio")
        }
        let money = left.kind == .money ? try left.money : try right.money
        let numeric = left.kind == .money ? try right.number : try left.number
        if left.kind == .money && (operation == "+" || operation == "-") && numeric.isPercentage {
            return .money(try MoneyValue(try quantities.binary(operation, money.magnitude, numeric), money.currency, money.rateStamp, money.exactDisplay))
        }
        if operation == "*" || operation == "of" || operation == "/" && left.kind == .money {
            return .money(try MoneyValue(left.kind == .money ? try quantities.binary(operation, money.magnitude, numeric) : try quantities.binary(operation, numeric, money.magnitude), money.currency, money.rateStamp, money.exactDisplay))
        }
        throw CalcError.arithmetic("Money requires another monetary value or a scalar/physical rate; bare-number addition is not defined")
    }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue {
        guard let firstArg = args.first, firstArg.kind == .money else { throw CalcError.arithmetic("Expected a monetary first argument") }
        let a = try firstArg.money; let key = name.netLower
        if key == "abs" && args.count == 1 { return .money(try MoneyValue(try quantities.function(key, [a.magnitude]), a.currency, a.rateStamp, a.exactDisplay)) }
        if (key == "whole" || key == "beforediscount") && args.count == 2 {
            return .money(try MoneyValue(try quantities.function(key, [a.magnitude, try args[1].number]), a.currency, a.rateStamp, a.exactDisplay))
        }
        if ["share", "change", "markup", "margin"].contains(key) && args.count == 2 {
            let b = try convert(try args[1].money, a.currency); _ = try MoneyArithmetic.merge(a, b)
            return .number(try quantities.function(key, [a.magnitude, b.magnitude]))
        }
        throw CalcError.arithmetic("Unsupported monetary function")
    }
    func aggregate(_ values: [SheetValue], _ average: Bool, _ token: CancellationToken) throws -> MoneyValue {
        guard let firstValue = values.first else { throw CalcError.arithmetic("No monetary values to aggregate") }
        let first = try firstValue.money; var converted: [NumericValue] = []; var provenance = first.rateStamp
        for item in values {
            try token.throwIfCancellationRequested(); let value = try convert(try item.money, first.currency)
            provenance = try MoneyArithmetic.merge(MoneyValue(first.magnitude, first.currency, provenance), value); converted.append(value.magnitude)
        }
        return try MoneyValue(try quantities.aggregate(converted, average, token), first.currency, provenance, try values.contains { try $0.money.exactDisplay })
    }
    func round(_ kind: RoundingKind, _ value: MoneyValue, _ precision: SheetValue, _ token: CancellationToken) throws -> MoneyValue {
        let quantum: NumericValue
        var provenance = value.rateStamp
        if kind == .increment && precision.kind == .money {
            let converted = try convert(try precision.money, value.currency); provenance = try MoneyArithmetic.merge(value, converted); quantum = converted.magnitude
        } else { quantum = try precision.number }
        return try MoneyValue(try quantities.round(kind, value.magnitude, quantum, token), value.currency, provenance, true)
    }
}
