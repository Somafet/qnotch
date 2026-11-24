import Foundation

extension UsageKind {
    /// C# `kind.ToString().ToLowerInvariant()`.
    var name: String { switch self { case .items: return "items"; case .tokens: return "tokens"; case .requests: return "requests" } }
}

/// A nonnegative count of tokens, requests or items, or a count per time (C# UsageCountValue).
struct UsageCountValue: Hashable {
    let quantity: NumericValue
    let kind: UsageKind
    var name: String { kind.name }
    /// The count in the display unit (count per that unit's time).
    private var shown: Rational { get throws { try quantity.exact.rational / (quantity.unit?.factor ?? .one) } }
    var display: String {
        get throws {
            try NumericValue(try shown).with { $0.isApproximate = quantity.isApproximate; $0.displayDecimalPlaces = quantity.displayDecimalPlaces }.display +
                " " + name + (quantity.unit?.moneySuffix() ?? "")
        }
    }
    var copyText: String { get throws { name + "(" + DeveloperSource.fraction(try shown) + ")" + (quantity.unit?.moneySuffix() ?? "") } }
    var details: String {
        get throws {
            "Usage kind: " + name + "; exact canonical count" + (quantity.unit == nil ? "" : " per second") + " = " + (try quantity.exact.text()) +
                "\nFractional counts/rates are estimates; no request, tokenization or provider is performed. Exact represented magnitude and display unit are retained."
        }
    }
    init(_ quantity: NumericValue, _ kind: UsageKind) throws {
        if !quantity.isRational || quantity.isPercentage || quantity.exact.constant.numerator.sign < 0 || !quantity.quantityKind.isEmpty ||
            quantity.unit.map({ $0.dimension != RateArithmetic.inverseTime }) == true {
            throw CalcError.arithmetic("Usage must be a nonnegative rational count or count/time rate")
        }
        self.quantity = quantity; self.kind = kind
    }
}

/// A flat supplied price per count of usage (C# UsagePriceValue).
struct UsagePriceValue: Hashable {
    let amount: MoneyValue
    let perCount: Rational
    let kind: UsageKind?
    var display: String {
        get throws {
            try MoneyValue(amount.magnitude, amount.currency, amount.rateStamp, true).display + "/" + (perCount == Rational(1_000_000) ? "M" : perCount.description) +
                (kind.map { " " + $0.name } ?? "")
        }
    }
    var copyText: String {
        get throws {
            (kind == .tokens ? "tokenPrice" : kind == .requests ? "requestPrice" : kind == .items ? "itemPrice" : "usagePrice") + "(" +
                DeveloperSource.fraction(try amount.magnitude.exact.rational) + " " + amount.currency + "," + DeveloperSource.fraction(perCount) + ")"
        }
    }
    var details: String {
        get throws {
            "Price: " + (try amount.magnitude.exact.text()) + " " + amount.currency + " per " + perCount.description + " " + (kind?.name ?? "items inferred from the count") +
                "\nFlat prorated arithmetic; supplied price only. No tiering, free allowance, minimum bill, tax, provider quote or actual invoice is inferred."
        }
    }
    init(_ amount: MoneyValue, _ perCount: Rational, _ kind: UsageKind?) throws {
        if amount.magnitude.unit != nil || !amount.magnitude.isRational || amount.magnitude.exact.constant.numerator.sign < 0 || perCount.numerator.sign <= 0 {
            throw CalcError.arithmetic("Unit price requires nonnegative plain money and a positive count denominator")
        }
        // The stored amount drops exact-display presentation, as C# rebuilds it from magnitude, currency and stamp.
        self.amount = try MoneyValue(amount.magnitude, amount.currency, amount.rateStamp); self.perCount = perCount; self.kind = kind
    }
}

/// A time-based downtime budget from an availability target (C# UptimeBudgetValue).
struct UptimeBudgetValue: Hashable {
    let availability: Rational
    let intervalSeconds: Rational
    let defaultInterval: Bool
    var downtimeSeconds: Rational { get throws { try (Rational.one - availability) * intervalSeconds } }
    var display: String {
        get throws {
            let n = try downtimeSeconds
            // Nearest whole second, halfway upward (the downtime is never negative).
            let rounded = try Rational((n.numerator * BigInt(2) + n.denominator) / (n.denominator * BigInt(2)))
            return try TimeSyntax.duration(ExactNumber(rounded), includeDays: true)
        }
    }
    var copyText: String {
        get throws {
            (defaultInterval ? "uptime(" : "downtime(") + "(" + DeveloperSource.fraction(try availability * Rational(100)) + ")%" +
                (defaultInterval ? "" : "," + DeveloperSource.fraction(intervalSeconds) + " s") + ")"
        }
    }
    var details: String {
        get throws {
            "Time-based downtime budget = (1 - " + availability.description + ") × " + intervalSeconds.description + " s = " + (try downtimeSeconds).description + " s" +
                (defaultInterval ? "\nDefault reporting interval: 365.25/12 days (30.4375 days), a mean-month convention." : "\nExplicit elapsed reporting interval; no calendar or request-based SLI inferred.") +
                "\nPreview rounds to the nearest whole second, halfway upward; exact duration is retained. This is a planning budget, not measured availability or an SLA guarantee."
        }
    }
    init(_ availability: Rational, _ interval: Rational, _ defaultInterval: Bool) throws {
        if availability.numerator.sign < 0 || availability.numerator > availability.denominator || interval.numerator.sign <= 0 {
            throw CalcError.arithmetic("Availability must be 0–100% and reporting duration positive")
        }
        self.availability = availability; intervalSeconds = interval; self.defaultInterval = defaultInterval
    }
}
