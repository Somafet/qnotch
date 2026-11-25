import Foundation

/// Exact/double bridges. Approximate results are rounded to a stated number of significant decimal digits.
enum FormulaNumbers {
    static func toDouble(_ value: Rational) -> Double {
        let numerator = value.numerator, denominator = value.denominator
        let numeratorShift = max(0, numerator.bitLength - 1000), denominatorShift = max(0, denominator.bitLength - 1000)
        return Foundation.scalbn((numerator >> numeratorShift).toDouble() / (denominator >> denominatorShift).toDouble(), numeratorShift - denominatorShift)
    }
    static func toDouble(_ value: ExactNumber) -> Double {
        var total = toDouble(value.constant)
        for term in value.radicals { total += toDouble(term.coefficient) * term.radicand.toDouble().squareRoot() }
        return total
    }
    /// Four decimals for approximate roots, widened to four significant digits below 0.001 so small distinct roots never both show as 0.
    static func rootPlaces(_ value: Double) -> Int {
        value == 0 || !value.isFinite || abs(value) >= 1e-3 ? 4 : min(24, 3 - Int(Foundation.floor(Foundation.log10(abs(value)))))
    }
    static func fromDouble(_ value: Double, _ significant: Int = 12) throws -> Rational {
        if !value.isFinite { throw CalcError.arithmetic("Result is not a finite number") }
        if value == 0 { return .zero }
        let significant = min(max(significant, 1), 16)
        // C# value.ToString("E<n>"): correctly rounded digits; printf rounds the same way.
        let text = String(format: "%.\(significant - 1)e", value)
        let split = text.netIndexOf("e")
        guard let digits = BigInt(text.netSubstring(0, split).netReplace(".", "")), let exponent = Int(text.netSubstring(split + 1)) else {
            throw CalcError.arithmetic("Result is not a finite number")
        }
        let shift = exponent - (significant - 1)
        return shift >= 0 ? try Rational(digits * BigInt.pow(10, shift)) : try Rational(digits, BigInt.pow(10, -shift))
    }
}
