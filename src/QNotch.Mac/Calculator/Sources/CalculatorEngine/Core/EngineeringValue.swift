import Foundation

/// Six-significant-figure engineering presentation; the underlying numeric value is unchanged.
final class EngineeringValue: Hashable, CustomStringConvertible {
    let original: NumericValue
    let display: String
    let copyText: String

    init(_ original: NumericValue, _ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) throws {
        if original.unit?.isTemperaturePoint == true { throw CalcError.arithmetic("Engineering notation requires a linear quantity, not an absolute temperature point") }
        self.original = original; let quantities = QuantityArithmetic(math)
        let rounded = try quantities.round(.significantFigures, original, NumericValue(Rational(6)), token)
        var unit = original.unit
        // A single decimal SI unit may move to the prefix that keeps the magnitude in [1, 1000): 4700 ohm shows as 4.7 kohm.
        if let current = unit, current.key.hasSuffix(":1"), !current.key.contains(";"), EngineeringValue.powerOfTen(current.factor) {
            for candidate in UnitCatalog.units {
                try budget.step(token)
                if candidate.dimension != current.dimension || candidate.isTemperaturePoint || candidate.kind != current.kind || !EngineeringValue.powerOfTen(candidate.factor) { continue }
                var magnitude = try rounded.exact.rational / candidate.factor
                if magnitude.sign < 0 { magnitude = try magnitude * Rational(-1) }
                if try (magnitude - Rational.one).sign >= 0 && (magnitude - Rational(1000)).sign < 0 { unit = try .single(candidate); break }
            }
        }
        var shown = unit == nil ? try rounded.exact.rational : try quantities.displayMagnitude(rounded.with { $0.unit = unit }).rational
        if original.isPercentage { shown = try shown * Rational(100) }
        var exponent = 0
        if shown.sign != 0 {
            let abs = shown.numerator.magnitude, denominator = shown.denominator
            var decimalExponent = abs.description.count - denominator.description.count
            if decimalExponent >= 0 ? abs < denominator * BigInt.pow(10, decimalExponent) : abs * BigInt.pow(10, -decimalExponent) < denominator { decimalExponent -= 1 }
            // C# integer division truncates toward zero, as Swift's does.
            exponent = (decimalExponent >= 0 ? decimalExponent / 3 : (decimalExponent - 2) / 3) * 3
        }
        let coefficient = exponent >= 0 ? try shown / Rational(BigInt.pow(10, exponent)) : try shown * Rational(BigInt.pow(10, -exponent))
        func superscript(_ value: Int) -> String {
            let digits = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
            return String(String(value).map { $0 == "-" ? "⁻" : digits[Int(String($0))!] })
        }
        display = (original.isApproximate ? "≈ " : "") + coefficient.description + (exponent == 0 ? "" : " × 10" + superscript(exponent)) +
            (original.isPercentage ? "%" : unit == nil ? "" : " " + unit!.symbol)
        if display.netLength > 2048 { throw CalcError.arithmetic("Engineering output limit exceeded") }
        let exact = original.unit == nil ? original.exact : try quantities.displayMagnitude(original)
        var source = try EngineeringValue.exactSource(exact)
        if original.isPercentage { source = "(" + source + "*100)%" }
        else if let originalUnit = original.unit { source = "(" + source + ") " + originalUnit.symbol }
        copyText = "engineering(" + source + (original.isApproximate ? ",1" : "") + ")"
    }
    private static func powerOfTen(_ value: Rational) -> Bool {
        var n = value.numerator, d = value.denominator
        while n > 1 && (n % 10).isZero { n /= 10 }
        while d > 1 && (d % 10).isZero { d /= 10 }
        return n.isOne && d.isOne
    }
    /// Decimal digits, split into 200-digit chunks recombined with powers of ten so a pasted copy stays under the literal limit.
    private static func integerSource(_ value: BigInt) throws -> String {
        if value.sign < 0 { return "(-" + (try integerSource(value.magnitude)) + ")" }
        let digits = value.description
        if digits.count <= 200 { return digits }
        let u = digits.units
        var result = u.string(0, 200)
        var offset = 200
        while offset < u.count {
            let chunk = u.string(offset, min(offset + 200, u.count))
            // BigInteger.Parse(chunk) drops the chunk's leading zeros.
            result = "(" + result + "*10^" + String(chunk.count) + "+" + BigInt(chunk)!.description + ")"
            offset += 200
        }
        return result
    }
    private static func exactSource(_ number: ExactNumber) throws -> String {
        func rationalSource(_ value: Rational) throws -> String {
            value.denominator.isOne ? try integerSource(value.numerator) : "(" + (try integerSource(value.numerator)) + "/" + (try integerSource(value.denominator)) + ")"
        }
        if number.isRational { return try rationalSource(number.constant) }
        return "(" + (try number.terms.map { term in try rationalSource(term.coefficient) + (term.radicand.isOne ? "" : "*sqrt(" + (try integerSource(term.radicand)) + ")") })
            .joined(separator: "+") + ")"
    }
    static func == (a: EngineeringValue, b: EngineeringValue) -> Bool { a === b || a.original == b.original }
    func hash(into hasher: inout Hasher) { hasher.combine(original) }
    var description: String { display }
}
