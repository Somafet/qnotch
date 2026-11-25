import Foundation

/// Bounded multiquadratic arithmetic. No floating point, probabilistic factoring or global caches.
final class ExactArithmetic {
    static let one = ExactNumber(Rational.one)
    private static let negativeRoot = "A negative quantity has no real square root, and complex values do not carry units or money"
    let budget: ExecutionBudget
    let token: CancellationToken
    init(_ budget: ExecutionBudget, _ token: CancellationToken) { self.budget = budget; self.token = token }
    private func step() throws { try budget.step(token) }

    func add(_ a: ExactNumber, _ b: ExactNumber) throws -> ExactNumber {
        if a.isRational && b.isRational { return ExactNumber(try a.constant + b.constant) }
        var terms: [BigInt: Rational] = [:]
        for term in a.terms + b.terms { try step(); try accumulate(&terms, term.radicand, term.coefficient) }
        return try ExactNumber(terms: terms)
    }
    func negate(_ value: ExactNumber) throws -> ExactNumber { try scale(value, Rational(-1)) }
    func subtract(_ a: ExactNumber, _ b: ExactNumber) throws -> ExactNumber { try add(a, negate(b)) }
    func scale(_ value: ExactNumber, _ factor: Rational) throws -> ExactNumber {
        if value.isRational { return ExactNumber(try value.constant * factor) }
        var terms: [BigInt: Rational] = [:]
        for term in value.terms { try step(); try accumulate(&terms, term.radicand, term.coefficient * factor) }
        return try ExactNumber(terms: terms)
    }
    func multiply(_ a: ExactNumber, _ b: ExactNumber) throws -> ExactNumber {
        if a.isRational { return try scale(b, a.constant) }
        if b.isRational { return try scale(a, b.constant) }
        var terms: [BigInt: Rational] = [:]
        for x in a.terms { for y in b.terms {
            try step()
            let common = BigInt.gcd(x.radicand, y.radicand)
            let radicand = (x.radicand / common) * (y.radicand / common)
            if radicand.bitLength > 4096 { throw CalcError.arithmetic("Precision limit exceeded") }
            try accumulate(&terms, radicand, x.coefficient * y.coefficient * Rational(common))
        } }
        return try ExactNumber(terms: terms)
    }
    private func accumulate(_ terms: inout [BigInt: Rational], _ radicand: BigInt, _ coefficient: Rational) throws {
        let sum = try (terms[radicand] ?? .zero) + coefficient
        if sum.isZero { terms[radicand] = nil } else { terms[radicand] = sum }
        if terms.count > 33 { throw CalcError.arithmetic("Radical term limit exceeded") }
    }
    func divide(_ a: ExactNumber, _ b: ExactNumber) throws -> ExactNumber {
        var a = a, b = b
        if b.isRational { return try scale(a, Rational.one / b.constant) }
        // Each conjugation removes a prime generator from the denominator's field.
        var pass = 0
        while !b.isRational {
            try step()
            if pass >= 16 { throw CalcError.arithmetic("Radical rationalization limit exceeded") }
            let single = b.radicals.count == 1
            let prime = single ? BigInt.one : try smallestFactor(b.radicals[0].radicand)
            var conjugate: [BigInt: Rational] = [:]
            for term in b.terms {
                conjugate[term.radicand] = !term.radicand.isOne && (single || (term.radicand % prime).isZero) ? -term.coefficient : term.coefficient
            }
            let c = try ExactNumber(terms: conjugate)
            a = try multiply(a, c); b = try multiply(b, c)
            pass += 1
        }
        return try scale(a, Rational.one / b.constant)
    }
    private func smallestFactor(_ value: BigInt) throws -> BigInt {
        var divisor = BigInt(2)
        while divisor * divisor <= value {
            try step()
            if (value % divisor).isZero { return divisor }
            divisor = divisor == 2 ? 3 : divisor + 2
        }
        return value
    }
    func squareRoot(_ value: ExactNumber) throws -> ExactNumber {
        try step()
        if !value.isRational {
            // Exact quadratic denesting; higher nested extensions remain explicit errors.
            let nested = "Nested radical is outside the supported exact field"
            if value.radicals.count != 1 { throw CalcError.arithmetic(nested) }
            let term = value.radicals[0], a = value.constant, b = term.coefficient
            if try sign(value) < 0 { throw CalcError.arithmetic(ExactArithmetic.negativeRoot) }
            let discriminant = try a * a - b * b * Rational(term.radicand)
            if discriminant.sign < 0 { throw CalcError.arithmetic(nested) }
            let root = try rationalRoot(discriminant)
            if !root.isRational { throw CalcError.arithmetic(nested) }
            let left = try (a + root.constant) / Rational(2), right = try (a - root.constant) / Rational(2)
            if left.sign < 0 || right.sign < 0 { throw CalcError.arithmetic(nested) }
            let answer = try add(rationalRoot(left), scale(rationalRoot(right), Rational(b.sign)))
            return try sign(answer) < 0 ? negate(answer) : answer
        }
        return try rationalRoot(value.constant)
    }
    private func rationalRoot(_ value: Rational) throws -> ExactNumber {
        if value.sign < 0 { throw CalcError.arithmetic(ExactArithmetic.negativeRoot) }
        if value.isZero { return .zero }
        let (outsideN, insideN) = try extractSquares(value.numerator)
        let (outsideD, insideD) = try extractSquares(value.denominator)
        let radicand = insideN * insideD
        if radicand.bitLength > 4096 { throw CalcError.arithmetic("Precision limit exceeded") }
        let coefficient = try Rational(outsideN, outsideD * insideD)
        return radicand.isOne ? ExactNumber(coefficient) : try ExactNumber(terms: [radicand: coefficient])
    }
    private func extractSquares(_ value: BigInt) throws -> (outside: BigInt, inside: BigInt) {
        var value = value
        var root = try integerRoot(value)
        if root * root == value { return (root, .one) }
        var outside = BigInt.one, inside = BigInt.one
        var divisor = BigInt(2)
        while divisor * divisor <= value {
            try step(); var count = 0
            while (value % divisor).isZero { try step(); value = value / divisor; count += 1 }
            if count != 0 {
                outside = outside * BigInt.pow(divisor, count / 2)
                if count & 1 != 0 { inside = inside * divisor }
                root = try integerRoot(value)
                if root * root == value { outside = outside * root; value = .one; break }
            }
            divisor = divisor == 2 ? 3 : divisor + 2
        }
        return (outside, inside * value)
    }
    func integerRoot(_ value: BigInt) throws -> BigInt {
        if value.isZero { return .zero }
        var root = BigInt.one << ((value.bitLength + 1) / 2)
        while true { try step(); let next = (root + value / root) / 2; if next >= root { return root }; root = next }
    }
    func power(_ value: ExactNumber, _ exponent: Rational) throws -> ExactNumber {
        var value = value, exponent = exponent
        if (!exponent.denominator.isOne && exponent.denominator != 2) || exponent.numerator.magnitude > 1024 {
            throw CalcError.arithmetic("Exponent must be an integer or half-integer with numerator from -1024 to 1024")
        }
        if exponent.denominator == 2 { value = try squareRoot(value); exponent = try Rational(exponent.numerator, .one) }
        var count = exponent.numerator.magnitude.intValue!; var answer = ExactArithmetic.one
        while count > 0 {
            try step()
            if count & 1 != 0 { answer = try multiply(answer, value) }
            count >>= 1
            if count > 0 { value = try multiply(value, value) }
        }
        return exponent.sign < 0 ? try divide(ExactArithmetic.one, answer) : answer
    }
    func bounds(_ value: ExactNumber, _ bits: Int) throws -> (lower: Rational, upper: Rational) {
        var lower = value.constant, upper = lower
        let denominator = BigInt.one << bits
        for term in value.radicals {
            try step()
            let root = try integerRoot(term.radicand << (2 * bits))
            let lo = try Rational(root, denominator) * term.coefficient
            let hi = try Rational(root + 1, denominator) * term.coefficient
            lower = try lower + (term.coefficient.sign > 0 ? lo : hi)
            upper = try upper + (term.coefficient.sign > 0 ? hi : lo)
        }
        return (lower, upper)
    }
    func sign(_ value: ExactNumber) throws -> Int {
        if value.isRational { return value.constant.sign }
        var bits = 16
        while bits <= 1024 {
            let (lo, hi) = try bounds(value, bits)
            if lo.sign > 0 { return 1 }
            if hi.sign < 0 { return -1 }
            bits *= 2
        }
        throw CalcError.arithmetic("Radical comparison precision limit exceeded")
    }
    static func floorRational(_ r: Rational) -> BigInt {
        let (q, remainder) = r.numerator.quotientAndRemainder(dividingBy: r.denominator)
        return r.numerator.sign < 0 && !remainder.isZero ? q - 1 : q
    }
    func floor(_ value: ExactNumber) throws -> BigInt {
        if value.isRational { return ExactArithmetic.floorRational(value.constant) }
        var bits = 16
        while bits <= 1024 {
            let (lo, hi) = try bounds(value, bits)
            let floor = ExactArithmetic.floorRational(lo)
            if floor == ExactArithmetic.floorRational(hi) { return floor }
            bits *= 2
        }
        throw CalcError.arithmetic("Radical comparison precision limit exceeded")
    }
}

/// The whole sheet's step allowance (C# SharedExecutionBudget).
final class SharedExecutionBudget {
    private var steps = 0
    func step() throws { steps += 1; if steps > SheetEvaluator.maxSheetSteps { throw CalcError.computationLimit } }
}

/// One expression's step and scope allowance (C# ExecutionBudget).
final class ExecutionBudget {
    private var steps = 0
    private var scopes = 0
    private let shared: SharedExecutionBudget?
    init(_ shared: SharedExecutionBudget? = nil) { self.shared = shared }
    /// Enters a nested evaluation scope; call `leaveScope` when done (C# `using budget.Scope()`).
    func enterScope() throws {
        scopes += 1
        if scopes > 64 { scopes -= 1; throw CalcError.arithmetic("Evaluation scope depth limit exceeded") }
    }
    func leaveScope() { scopes -= 1 }
    @inline(__always) func step(_ token: CancellationToken) throws {
        try token.throwIfCancellationRequested()
        steps += 1
        if steps > 16384 { throw CalcError.arithmetic("Expression step limit exceeded") }
        try shared?.step()
    }
}
