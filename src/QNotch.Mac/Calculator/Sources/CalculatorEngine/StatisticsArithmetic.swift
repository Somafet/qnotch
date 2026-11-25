import Foundation

final class StatisticsArithmetic {
    private let math: ExactArithmetic
    private let budget: ExecutionBudget
    private let token: CancellationToken
    private let money: MoneyArithmetic
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic) {
        self.math = math; self.budget = budget; self.token = token; self.money = money
    }
    static func isFunction(_ name: String) -> Bool {
        ["sum", "mean", "average", "avg", "median", "min", "max", "count", "stdev", "stddev", "stdevp", "variance", "variancep", "percentile"].contains(name.netLower)
    }
    static func validateArity(_ name: String, _ count: Int) throws {
        if name.equalsIgnoreCase("percentile") { if count != 2 { throw CalcError.format("percentile expects 2 arguments") } }
        else if count < 1 || count > 16 { throw CalcError.format("\(name) expects 1–16 arguments or a list") }
    }
    /// List arguments contribute their items; every value must be a number or money.
    static func flatten<S: Sequence>(_ arguments: S, _ budget: ExecutionBudget, _ token: CancellationToken) throws -> [SheetValue] where S.Element == SheetValue {
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
    func function(_ name: String, _ args: [SheetValue]) throws -> (value: SheetValue, assumption: String) {
        try StatisticsArithmetic.validateArity(name, args.count); let key = name.netLower
        let values = try StatisticsArithmetic.flatten(key == "percentile" ? Array(args.prefix(1)) : args, budget, token)
        if key == "count" { return (SheetValue(Rational(values.count)), "\(values.count) list/scalar entries; exact count; no text, dates or invalid values silently skipped") }
        if values.isEmpty {
            if key == "sum" { return (SheetValue(Rational.zero), "Empty numeric sum is zero") }
            throw CalcError.arithmetic("Statistics require a nonempty sample")
        }
        var currency: MoneyValue? = values[0].kind == .money ? try values[0].money : nil
        var numbers: [NumericValue] = []; numbers.reserveCapacity(values.count)
        for value in values {
            try budget.step(token)
            if (value.kind == .money) != (currency != nil) { throw CalcError.arithmetic("Do not mix bare and monetary statistical samples") }
            guard let sampleCurrency = currency else { numbers.append(try value.number); continue }
            let converted = try money.convert(try value.money, sampleCurrency.currency)
            if sampleCurrency.rateStamp != nil && converted.rateStamp != nil && sampleCurrency.rateSnapshotKey != converted.rateSnapshotKey {
                throw CalcError.arithmetic("Statistical sample uses different currency snapshots")
            }
            currency = try MoneyValue(sampleCurrency.magnitude, sampleCurrency.currency, sampleCurrency.rateStamp ?? converted.rateStamp)
            numbers.append(converted.magnitude)
        }
        let first = numbers[0]; var kind = first.quantityKind
        for number in numbers {
            if number.unit?.dimension != first.unit?.dimension || number.isPercentage != first.isPercentage || number.unit?.isTemperaturePoint != first.unit?.isTemperaturePoint {
                throw CalcError.arithmetic("Statistical sample requires compatible dimensions and value types")
            }
            if !kind.isEmpty && !number.quantityKind.isEmpty && kind != number.quantityKind { throw CalcError.arithmetic("Statistical sample contains incompatible quantity kinds") }
            if kind.isEmpty { kind = number.quantityKind }
        }
        var approximate = numbers.contains { $0.isApproximate }
        let quantities = QuantityArithmetic(math)
        func wrap(_ number: NumericValue) throws -> SheetValue {
            guard let currency else { return .number(number) }
            return .money(try MoneyValue(number, currency.currency, currency.rateStamp))
        }
        func result(_ number: NumericValue, _ convention: String) throws -> (value: SheetValue, assumption: String) {
            (try wrap(number.with { $0.isApproximate = number.isApproximate || approximate }), "\(values.count) values; " + convention +
                "; exact represented magnitudes, display rounding retained separately" + (money.provenance.map { "; " + $0 } ?? ""))
        }
        func location(_ exact: ExactNumber) -> NumericValue {
            first.with {
                $0.exact = exact; $0.quantityKind = kind; $0.isApproximate = approximate; $0.displayDecimalPlaces = 4; $0.useCompoundDuration = false; $0.useDaysInDuration = false
            }
        }
        if key == "sum" { return try result(try quantities.aggregate(numbers, false, token), "Numeric sum; absolute temperatures cannot be summed") }
        if key == "mean" || key == "average" || key == "avg" {
            let mean = try quantities.aggregate(numbers, true, token).with { $0.displayDecimalPlaces = 4; $0.useCompoundDuration = false; $0.useDaysInDuration = false }
            return try result(mean, "Arithmetic mean; sum / count; first sample unit/currency retained")
        }
        if ["variance", "variancep", "stdev", "stddev", "stdevp"].contains(key) {
            let population = key == "variancep" || key == "stdevp", deviation = key == "stdev" || key == "stddev" || key == "stdevp"
            if !population && numbers.count < 2 { throw CalcError.arithmetic("Sample variance/deviation requires at least two values") }
            if !deviation && currency != nil { throw CalcError.arithmetic("Monetary variance has squared currency units; use stdev or numeric magnitudes") }
            var sum = ExactNumber.zero
            for number in numbers { try budget.step(token); sum = try math.add(sum, number.exact) }
            let mean = try math.scale(sum, Rational(BigInt(1), BigInt(numbers.count))); var squares = ExactNumber.zero
            for number in numbers {
                try budget.step(token); let distance = try math.subtract(number.exact, mean)
                squares = try math.add(squares, try math.multiply(distance, distance))
            }
            let divisor = numbers.count - (population ? 0 : 1)
            let variance = try math.scale(squares, Rational(BigInt(1), BigInt(divisor)))
            let exact = deviation ? try math.squareRoot(variance) : variance
            var unit = try first.unit?.delta()
            if !deviation { unit = try unit?.power(Rational(2)) }
            let output = (unit == nil ? NumericValue(exact, isPercentage: deviation && first.isPercentage) : NumericValue(exact, unit: unit!)).with {
                $0.isApproximate = approximate; $0.displayDecimalPlaces = 4
            }
            return try result(output, (population ? "Population" : "Sample") +
                (deviation ? " standard deviation; square root of centered sum of squares / " : " variance; centered sum of squares / ") + String(divisor) +
                (first.unit?.isTemperaturePoint == true ? "; temperature dispersion is a difference, not an absolute temperature" : "") +
                (first.isPercentage && !deviation ? "; percentage variance expressed in squared ratios" : ""))
        }
        if key == "min" || key == "max" {
            var selected = first.exact
            for number in numbers {
                try budget.step(token); let comparison = try math.sign(math.subtract(number.exact, selected))
                if key == "min" ? comparison < 0 : comparison > 0 { selected = number.exact }
            }
            return try result(first.with { $0.exact = selected; $0.quantityKind = kind }, "Exact ordering of represented magnitudes; first sample unit/currency retained")
        }
        let ordered = try sort(numbers)
        let fraction: Rational
        if key == "median" { fraction = try Rational(1, 2) }
        else {
            let percentile = try args[1].number
            if percentile.unit != nil || !percentile.isRational { throw CalcError.arithmetic("Percentile requires a dimensionless rational from 0 to 100 (or 0% to 100%)") }
            fraction = percentile.isPercentage ? try percentile.scalar : try percentile.scalar / Rational(100)
            if fraction.numerator.sign < 0 || fraction.numerator > fraction.denominator { throw CalcError.arithmetic("Percentile must be from 0 to 100 (or 0% to 100%)") }
            approximate = approximate || percentile.isApproximate
        }
        let rank = try fraction * Rational(ordered.count - 1)
        let index = (rank.numerator / rank.denominator).intValue!; let remainder = try rank - Rational(index)
        var located = ordered[index].exact
        if !remainder.numerator.isZero {
            located = try math.add(located, try math.scale(try math.subtract(ordered[index + 1].exact, located), remainder))
        }
        return try result(location(located), key == "median" ? "Median; sorted middle value or arithmetic mean of the two middle values" :
            "Inclusive linear percentile; zero-based rank (n-1)*p; bare p is percentage points, % input is a ratio; no nearest-rank substitution")
    }
    private func sort(_ numbers: [NumericValue]) throws -> [NumericValue] {
        // Stable bounded merge sort. Comparer failures propagate directly, rather than being wrapped by Array.Sort.
        var sorted = numbers, temporary = numbers
        var width = 1
        while width < sorted.count {
            var start = 0
            while start < sorted.count {
                let middle = min(start + width, sorted.count), end = min(start + width * 2, sorted.count)
                var left = start, right = middle
                for target in start..<end {
                    try budget.step(token)
                    if try right == end || left < middle && math.sign(math.subtract(sorted[left].exact, sorted[right].exact)) <= 0 { temporary[target] = sorted[left]; left += 1 }
                    else { temporary[target] = sorted[right]; right += 1 }
                }
                start += width * 2
            }
            swap(&sorted, &temporary)
            width *= 2
        }
        return sorted
    }
}
