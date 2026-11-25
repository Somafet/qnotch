import Foundation

enum RoundingKind { case decimalPlaces, increment, significantFigures }

enum ExactRounding {
    static func apply(_ kind: RoundingKind, _ operand: NumericValue, _ precision: NumericValue, _ token: CancellationToken, _ math: ExactArithmetic? = nil) throws -> NumericValue {
        try token.throwIfCancellationRequested()
        if !operand.isRational || !precision.isRational { return try applyRadical(kind, operand, precision, math ?? ExactArithmetic(ExecutionBudget(), token)) }
        if kind == .increment {
            if operand.isPercentage != precision.isPercentage { throw CalcError.format("Rounding increment must have the same value type") }
            if try precision.scalar.sign <= 0 { throw CalcError.arithmetic("Rounding increment must be positive") }
            return NumericValue(try toIncrement(operand.scalar, precision.scalar, token), isPercentage: operand.isPercentage)
        }
        let minimum = kind == .decimalPlaces ? 0 : 1
        if precision.isPercentage { throw CalcError.arithmetic("Rounding precision must be an integer from \(minimum) to 256") }
        let p = try precision.scalar
        if !p.denominator.isOne || p.numerator < BigInt(minimum) || p.numerator > 256 { throw CalcError.arithmetic("Rounding precision must be an integer from \(minimum) to 256") }
        let count = p.numerator.intValue!
        let value = operand.isPercentage ? try operand.scalar * Rational(100) : try operand.scalar
        if value.isZero { return operand }
        let exponent = kind == .decimalPlaces ? -count : try magnitude(value, token) - count + 1
        let scale = try powerOfTen(exponent, token)
        let rounded = try toIncrement(value, scale, token)
        return NumericValue(operand.isPercentage ? try rounded / Rational(100) : rounded, isPercentage: operand.isPercentage)
    }
    private static func applyRadical(_ kind: RoundingKind, _ operand: NumericValue, _ precision: NumericValue, _ math: ExactArithmetic) throws -> NumericValue {
        let increment: ExactNumber
        if kind == .increment {
            if operand.isPercentage != precision.isPercentage { throw CalcError.format("Rounding increment must have the same value type") }
            if try math.sign(precision.exact) <= 0 { throw CalcError.arithmetic("Rounding increment must be positive") }
            increment = precision.exact
        } else {
            let minimum = kind == .decimalPlaces ? 0 : 1
            guard precision.isRational, !precision.isPercentage else { throw CalcError.arithmetic("Rounding precision must be an integer from \(minimum) to 256") }
            let p = try precision.scalar
            guard p.denominator.isOne, p.numerator >= BigInt(minimum), p.numerator <= 256 else { throw CalcError.arithmetic("Rounding precision must be an integer from \(minimum) to 256") }
            let count = p.numerator.intValue!
            let value = operand.isPercentage ? try math.scale(operand.exact, Rational(100)) : operand.exact
            if value.isZero { return operand }
            var magnitude = 0
            if kind == .significantFigures {
                let absolute = try math.sign(value) < 0 ? try math.negate(value) : value
                while try math.sign(math.subtract(absolute, ExactNumber(powerOfTen(magnitude, .none)))) < 0 { magnitude -= 1 }
                while try math.sign(math.subtract(absolute, ExactNumber(powerOfTen(magnitude + 1, .none)))) >= 0 { magnitude += 1 }
            }
            let exponent = kind == .decimalPlaces ? -count : magnitude - count + 1
            let quantum = try powerOfTen(exponent, .none)
            increment = ExactNumber(operand.isPercentage ? try quantum / Rational(100) : quantum)
        }
        var quotient = try math.divide(operand.exact, increment); let sign = try math.sign(quotient)
        if sign < 0 { quotient = try math.negate(quotient) }
        var whole = try math.floor(quotient)
        let halfway = ExactNumber(try Rational(whole * 2 + 1, BigInt(2)))
        if try math.sign(math.subtract(quotient, halfway)) >= 0 { whole = whole + 1 }
        return NumericValue(try math.scale(increment, Rational(BigInt(sign) * whole)), isPercentage: operand.isPercentage)
    }
    private static func powerOfTen(_ exponent: Int, _ token: CancellationToken) throws -> Rational {
        try token.throwIfCancellationRequested()
        // 10^1233 fits 4096 bits; reject before constructing a larger decimal quantum.
        if abs(exponent) > 1233 { throw CalcError.arithmetic("Precision limit exceeded") }
        let power = BigInt.pow(10, abs(exponent))
        return exponent < 0 ? try Rational(.one, power) : try Rational(power)
    }
    private static func magnitude(_ value: Rational, _ token: CancellationToken) throws -> Int {
        let numerator = value.numerator.magnitude, denominator = value.denominator
        var exponent = numerator.description.count - denominator.description.count
        try token.throwIfCancellationRequested()
        let power = BigInt.pow(10, abs(exponent))
        // Compare exactly with 10^exponent: a logarithm can misclassify values close to powers of ten.
        if exponent >= 0 ? numerator < denominator * power : numerator * power < denominator { exponent -= 1 }
        return exponent
    }
    private static func toIncrement(_ value: Rational, _ increment: Rational, _ token: CancellationToken) throws -> Rational {
        try token.throwIfCancellationRequested()
        // Both inputs have <=4096-bit components, bounding these temporary integer products to 8192 bits.
        let numerator = value.numerator.magnitude * increment.denominator
        let denominator = value.denominator * increment.numerator
        var (whole, remainder) = numerator.quotientAndRemainder(dividingBy: denominator)
        if remainder * 2 >= denominator { whole = whole + 1 }
        try token.throwIfCancellationRequested()
        // Cancel before multiplication so a representable answer is not rejected for an unreduced product.
        let common = BigInt.gcd(whole, increment.denominator)
        return try Rational(BigInt(value.numerator.sign) * (whole / common) * increment.numerator, increment.denominator / common)
    }
}
