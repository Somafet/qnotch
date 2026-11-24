import Foundation

/// Bounded complex arithmetic over exact parts. Results fall back to marked doubles only where no simple exact form exists.
final class ComplexArithmetic {
    static let convention = "Exact parts where representable; principal values, arg in radians over (-pi, pi]; plain numbers only: no units, money, lists or matrices"
    static let refusal = "Complex values combine only with plain numbers, not units, percentages, money, lists or matrices"
    private static let exponentError = "Complex powers require an exact integer or half-integer exponent from -1024 to 1024"
    private static let smallRootBits = 24 // Trial square extraction stays far inside the expression budget.
    private struct Parts {
        var re: ExactNumber, im: ExactNumber, approximate: Bool
        init(_ re: ExactNumber, _ im: ExactNumber, _ approximate: Bool) { self.re = re; self.im = im; self.approximate = approximate }
    }
    private let math: ExactArithmetic
    private let quantities: QuantityArithmetic
    private let budget: ExecutionBudget
    private let token: CancellationToken
    init(_ math: ExactArithmetic, _ quantities: QuantityArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) {
        self.math = math; self.quantities = quantities; self.budget = budget; self.token = token
    }
    static func isFunction(_ name: String) -> Bool { ["re", "im", "conj", "arg"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws { if count != 1 { throw CalcError.format("\(name) expects 1 argument(s)") } }
    private static func plain(_ value: SheetValue) -> Bool { if case .number(let n) = value { return n.unit == nil && !n.isPercentage }; return false }
    private static func operand(_ value: SheetValue) throws -> Parts {
        if case .complex(let z) = value { return Parts(z.real, z.imaginary, z.isApproximate) }
        if plain(value), case .number(let n) = value { return Parts(n.exact, .zero, n.isApproximate) }
        throw CalcError.arithmetic(refusal)
    }
    private static func make(_ re: ExactNumber, _ im: ExactNumber, _ approximate: Bool) throws -> SheetValue {
        im.isZero ? .number(NumericValue(re).with { $0.isApproximate = approximate }) : .complex(try ComplexValue(re, im, approximate))
    }
    private static func make(_ z: Parts) throws -> SheetValue { try make(z.re, z.im, z.approximate) }
    private static func approximate(_ value: Double) throws -> ExactNumber { ExactNumber(try FormulaNumbers.fromDouble(value)) }
    private func negative(_ value: SheetValue) throws -> Bool {
        guard ComplexArithmetic.plain(value), case .number(let n) = value else { return false }
        return try math.sign(n.exact) < 0
    }
    /// True when a binary operation has a complex operand or takes a half-integer power of a negative real.
    func applies(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> Bool {
        if left.kind == .complex || right.kind == .complex { return true }
        guard operation == "^", try negative(left), ComplexArithmetic.plain(right), case .number(let exponent) = right, !exponent.isApproximate, exponent.isRational else { return false }
        return try exponent.scalar.denominator == 2
    }
    func applies(_ name: String, _ args: [SheetValue]) throws -> Bool {
        if ComplexArithmetic.isFunction(name) { return true }
        guard args.count == 1 else { return false }
        if name.equalsIgnoreCase("abs") && args[0].kind == .complex { return true }
        return try name.equalsIgnoreCase("sqrt") && (args[0].kind == .complex || negative(args[0]))
    }
    private func sum(_ a: Parts, _ b: Parts, subtract: Bool = false) throws -> Parts {
        Parts(subtract ? try math.subtract(a.re, b.re) : try math.add(a.re, b.re), subtract ? try math.subtract(a.im, b.im) : try math.add(a.im, b.im), a.approximate || b.approximate)
    }
    private func product(_ a: Parts, _ b: Parts) throws -> Parts {
        Parts(try math.subtract(math.multiply(a.re, b.re), math.multiply(a.im, b.im)), try math.add(math.multiply(a.re, b.im), math.multiply(a.im, b.re)), a.approximate || b.approximate)
    }
    private func norm(_ z: Parts) throws -> ExactNumber { try math.add(math.multiply(z.re, z.re), math.multiply(z.im, z.im)) }
    private func quotient(_ a: Parts, _ b: Parts) throws -> Parts {
        let norm = try norm(b); var conjugate = b; conjugate.im = try math.negate(b.im)
        var product = try product(a, conjugate)
        product.re = try math.divide(product.re, norm); product.im = try math.divide(product.im, norm)
        return product
    }
    static func literal(_ coefficient: Rational) throws -> SheetValue { try make(.zero, ExactNumber(coefficient), false) }
    func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue {
        try budget.step(token)
        let a = try ComplexArithmetic.operand(left)
        if operation == "^" { return try ComplexArithmetic.make(try power(a, right)) }
        let b = try ComplexArithmetic.operand(right)
        switch operation {
        case "+": return try ComplexArithmetic.make(try sum(a, b))
        case "-": return try ComplexArithmetic.make(try sum(a, b, subtract: true))
        case "*", "of": return try ComplexArithmetic.make(try product(a, b))
        case "/": return try ComplexArithmetic.make(try quotient(a, b))
        default: throw CalcError.arithmetic("Unsupported complex operation: " + operation)
        }
    }
    func unary(_ operation: String, _ value: SheetValue) throws -> SheetValue {
        try budget.step(token); let z = try ComplexArithmetic.operand(value)
        switch operation {
        case "+": return try ComplexArithmetic.make(z)
        case "-": return try ComplexArithmetic.make(Parts(try math.negate(z.re), try math.negate(z.im), z.approximate))
        default: throw CalcError.arithmetic("Unsupported complex operation: " + operation)
        }
    }
    func scale(_ value: SheetValue, _ factor: Rational) throws -> SheetValue {
        try budget.step(token); let z = try ComplexArithmetic.operand(value)
        return try ComplexArithmetic.make(Parts(try math.scale(z.re, factor), try math.scale(z.im, factor), z.approximate))
    }
    func round(_ kind: RoundingKind, _ value: SheetValue, _ precision: NumericValue) throws -> SheetValue {
        try budget.step(token); let z = try ComplexArithmetic.operand(value)
        return try ComplexArithmetic.make(try quantities.round(kind, NumericValue(z.re), precision, token).exact, try quantities.round(kind, NumericValue(z.im), precision, token).exact, z.approximate)
    }
    private func power(_ base: Parts, _ exponent: SheetValue) throws -> Parts {
        var z = base
        if exponent.kind == .complex { throw CalcError.arithmetic("Complex exponents are not supported") }
        guard ComplexArithmetic.plain(exponent), case .number(let number) = exponent, !number.isApproximate, number.isRational else { throw CalcError.arithmetic(ComplexArithmetic.exponentError) }
        let power = try number.scalar; let magnitude = power.numerator.magnitude
        if power.denominator > BigInt(2) || magnitude > BigInt(1024) { throw CalcError.arithmetic(ComplexArithmetic.exponentError) }
        if power.denominator == 2 { z = try root(z) }
        var count = magnitude.intValue!; var answer = Parts(ExactArithmetic.one, .zero, z.approximate)
        while count > 0 {
            try budget.step(token)
            if count & 1 != 0 { answer = try product(answer, z) }
            count >>= 1
            if count > 0 { z = try product(z, z) }
        }
        return power.numerator.sign < 0 ? try quotient(Parts(ExactArithmetic.one, .zero, false), answer) : answer
    }
    /// A rational root stays exact when it is a perfect square or small enough to extract squares; nil otherwise.
    private func exactRoot(_ value: Rational) throws -> ExactNumber? {
        let n = try math.integerRoot(value.numerator), d = try math.integerRoot(value.denominator)
        if n * n == value.numerator && d * d == value.denominator { return ExactNumber(try Rational(n, d)) }
        return value.numerator.bitLength <= ComplexArithmetic.smallRootBits && value.denominator.bitLength <= ComplexArithmetic.smallRootBits ? try math.squareRoot(ExactNumber(value)) : nil
    }
    private func root(_ z: Parts) throws -> Parts {
        try budget.step(token); let approximate = z.approximate; let half = try Rational(1, 2)
        if z.im.isZero, try math.sign(z.re) >= 0 {
            return approximate ? Parts(try ComplexArithmetic.approximate(FormulaNumbers.toDouble(z.re).squareRoot()), .zero, true) : Parts(try math.squareRoot(z.re), .zero, false)
        }
        if z.im.isZero {
            return approximate ? Parts(.zero, try ComplexArithmetic.approximate((-FormulaNumbers.toDouble(z.re)).squareRoot()), true) : Parts(.zero, try math.squareRoot(math.negate(z.re)), false)
        }
        if !approximate && z.re.isRational && z.im.isRational, let modulus = try exactRoot(try z.re.constant * z.re.constant + z.im.constant * z.im.constant), modulus.isRational {
            let outer = try exactRoot(try (modulus.constant + z.re.constant) * half), inner = try exactRoot(try (modulus.constant - z.re.constant) * half)
            if let re = outer, let im = inner { return Parts(re, try math.sign(z.im) < 0 ? try math.negate(im) : im, false) }
        }
        let a = FormulaNumbers.toDouble(z.re), b = FormulaNumbers.toDouble(z.im)
        let large = ((ComplexArithmetic.hypot(a, b) + Swift.abs(a)) / 2).squareRoot(), small = Swift.abs(b) / (2 * large)
        let sign: Double = b < 0 ? -1 : 1
        return a >= 0 ? Parts(try ComplexArithmetic.approximate(large), try ComplexArithmetic.approximate(sign * small), true)
            : Parts(try ComplexArithmetic.approximate(small), try ComplexArithmetic.approximate(sign * large), true)
    }
    private static func hypot(_ a: Double, _ b: Double) -> Double {
        let scale = max(Swift.abs(a), Swift.abs(b))
        return scale == 0 ? 0 : scale * (a / scale * (a / scale) + b / scale * (b / scale)).squareRoot()
    }
    private func modulus(_ z: Parts) throws -> SheetValue {
        let norm = try norm(z)
        if !z.approximate && norm.isRational, let exact = try exactRoot(norm.constant) { return .number(NumericValue(exact)) }
        return .number(NumericValue(try FormulaNumbers.fromDouble(ComplexArithmetic.hypot(FormulaNumbers.toDouble(z.re), FormulaNumbers.toDouble(z.im)))).with { $0.isApproximate = true })
    }
    private func angle(_ z: Parts) throws -> SheetValue {
        if z.im.isZero && z.re.isZero { throw CalcError.arithmetic("arg is undefined at 0") }
        if z.im.isZero, try math.sign(z.re) > 0 { return .number(NumericValue(Rational.zero).with { $0.isApproximate = z.approximate }) }
        return .number(NumericValue(try FormulaNumbers.fromDouble(Foundation.atan2(FormulaNumbers.toDouble(z.im), FormulaNumbers.toDouble(z.re)))).with { $0.isApproximate = true })
    }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue {
        try ComplexArithmetic.validateArity(name, args.count); try budget.step(token); let z = try ComplexArithmetic.operand(args[0])
        switch name.netLower {
        case "re": return try ComplexArithmetic.make(z.re, .zero, z.approximate)
        case "im": return try ComplexArithmetic.make(z.im, .zero, z.approximate)
        case "conj": return try ComplexArithmetic.make(Parts(z.re, try math.negate(z.im), z.approximate))
        case "abs": return try modulus(z)
        case "arg": return try angle(z)
        case "sqrt": return try ComplexArithmetic.make(try root(z))
        default: throw CalcError.format("Unknown function: \(name)")
        }
    }
}
