import Foundation

/// Bounded rational polynomial arithmetic and square-free Sturm isolation, in ascending coefficient order.
final class EquationPolynomial {
    private typealias F = EquationFraction
    private let math: ExactArithmetic
    private let budget: ExecutionBudget
    private let token: CancellationToken
    private var refinements = 0
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) { self.math = math; self.budget = budget; self.token = token }
    private func step() throws { try budget.step(token) }

    func trim(_ p: [Rational]) -> [Rational] {
        var n = p.count
        while n > 0 && p[n - 1].numerator.isZero { n -= 1 }
        return Array(p.prefix(n))
    }
    func sum(_ a: [Rational], _ b: [Rational], subtract: Bool = false) throws -> [Rational] {
        try step()
        var p = [Rational](repeating: .zero, count: max(a.count, b.count))
        for i in 0..<p.count {
            let right = i < b.count ? b[i] : .zero
            p[i] = try F.add(i < a.count ? a[i] : .zero, subtract ? F.negate(right) : right)
        }
        return trim(p)
    }
    func product(_ a: [Rational], _ b: [Rational]) throws -> [Rational] {
        try step()
        if a.isEmpty || b.isEmpty { return [] }
        if a.count + b.count - 2 > FormulaPolynomial.maxDegree { throw CalcError.arithmetic("Polynomial degree limit is \(FormulaPolynomial.maxDegree)") }
        var p = [Rational](repeating: .zero, count: a.count + b.count - 1)
        for i in 0..<a.count { for j in 0..<b.count { try token.throwIfCancellationRequested(); p[i + j] = try F.add(p[i + j], F.multiply(a[i], b[j])) } }
        return trim(p)
    }
    func scale(_ p: [Rational], _ scalar: Rational) throws -> [Rational] { try step(); return trim(try p.map { try F.multiply($0, scalar) }) }
    func power(_ p: [Rational], _ exponent: Int) throws -> [Rational] {
        var result: [Rational] = [.one]
        for _ in 0..<max(0, exponent) { result = try product(result, p) }
        return result
    }
    func evaluate(_ p: [Rational], _ x: Rational) throws -> Rational {
        try step()
        var value = Rational.zero
        for c in p.reversed() { value = try F.add(F.multiply(value, x), c) }
        return value
    }
    func evaluateExact(_ p: [Rational], _ x: ExactNumber) throws -> ExactNumber {
        try step()
        var value = ExactNumber.zero
        for c in p.reversed() { value = try math.add(math.multiply(value, x), ExactNumber(c)) }
        return value
    }
    func derivative(_ p: [Rational]) throws -> [Rational] {
        try step()
        return trim(try p.dropFirst().enumerated().map { try F.multiply($0.element, Rational($0.offset + 1)) })
    }
    func antiderivative(_ p: [Rational]) throws -> [Rational] {
        try step()
        return trim([.zero] + (try p.enumerated().map { try F.divide($0.element, Rational($0.offset + 1)) }))
    }
    private func dividePolynomial(_ a: [Rational], _ b: [Rational]) throws -> (quotient: [Rational], remainder: [Rational]) {
        try step()
        if b.isEmpty { throw CalcError.arithmetic("Zero polynomial divisor") }
        var r = a; var q = [Rational](repeating: .zero, count: max(0, a.count - b.count + 1))
        var k = a.count - b.count
        while k >= 0 {
            try token.throwIfCancellationRequested()
            let factor = try F.divide(r[k + b.count - 1], b[b.count - 1]); q[k] = factor
            for j in 0..<b.count { r[k + j] = try F.subtract(r[k + j], F.multiply(factor, b[j])) }
            k -= 1
        }
        return (trim(q), trim(r))
    }
    // Positive scaling preserves Sturm signs.
    private func normalize(_ p: [Rational]) throws -> [Rational] { p.isEmpty ? p : try scale(p, F.divide(.one, F.abs(p[p.count - 1]))) }
    private func chain(_ p: [Rational]) throws -> [[Rational]] {
        var list = [try normalize(p), try normalize(derivative(p))]
        while !list[list.count - 1].isEmpty {
            let remainder = try dividePolynomial(list[list.count - 2], list[list.count - 1]).remainder
            if remainder.isEmpty { break }
            list.append(try normalize(scale(remainder, Rational(-1))))
        }
        return list
    }
    private func variations(_ chain: [[Rational]], _ at: Rational) throws -> Int {
        var previous = 0, changes = 0
        for p in chain {
            let sign = try evaluate(p, at).numerator.sign
            if sign == 0 { continue }
            if previous != 0 && previous != sign { changes += 1 }
            previous = sign
        }
        return changes
    }
    private static func accurate(_ lo: Rational, _ hi: Rational) throws -> Bool {
        var scale = F.abs(try F.half(F.add(lo, hi)))
        if F.compare(scale, .one) < 0 { scale = .one }
        return F.compare(try F.subtract(hi, lo), try F.divide(scale, Rational(BigInt.pow(10, 14)))) <= 0
    }
    private func reconstruct(_ p: [Rational], _ lo: Rational, _ hi: Rational) throws -> Rational? {
        let value = try F.half(F.add(lo, hi)); var n = value.numerator, d = value.denominator
        var hn = BigInt.one, hp = BigInt.zero, kn = BigInt.zero, kp = BigInt.one
        var i = 0
        while i < 64 && !d.isZero {
            try step()
            var (a, rem) = n.quotientAndRemainder(dividingBy: d)
            if rem.sign < 0 { a -= 1; rem += d }
            let h = a * hn + hp, k = a * kn + kp
            if k.bitLength > 40 { break }
            if !k.isZero {
                let candidate = try Rational(h, k)
                if try F.compare(candidate, lo) >= 0 && F.compare(candidate, hi) <= 0 && evaluate(p, candidate).numerator.isZero { return candidate }
            }
            hp = hn; hn = h; kp = kn; kn = k; n = d; d = rem
            i += 1
        }
        return nil
    }
    private typealias Cell = (lo: Rational, hi: Rational, vLo: Int, vHi: Int)
    /// All distinct real roots of p inside the optional closed domain; repeated roots once. Complex roots are never reported.
    func solve(_ polynomial: [Rational], _ domainLo: Rational? = nil, _ domainHi: Rational? = nil) throws -> (roots: [EquationRoot], identity: Bool, method: String) {
        var p = trim(polynomial)
        if p.count <= 1 { return ([], p.isEmpty, "Exact constant polynomial classification") }
        func inside(_ value: ExactNumber) throws -> Bool {
            try (domainLo.map { try math.sign(math.subtract(value, ExactNumber($0))) >= 0 } ?? true) &&
                (domainHi.map { try math.sign(math.subtract(value, ExactNumber($0))) <= 0 } ?? true)
        }
        func exact(_ value: ExactNumber) -> EquationRoot { EquationRoot(NumericValue(value)) }
        if p.count == 2 {
            let root = ExactNumber(try F.divide(F.negate(p[0]), p[1]))
            return (try inside(root) ? [exact(root)] : [], false, "Exact linear solution -b/a")
        }
        if p.count == 3 {
            let discriminant = try F.subtract(F.multiply(p[1], p[1]), F.multiply(Rational(4), F.multiply(p[2], p[0])))
            if discriminant.numerator.sign < 0 { return ([], false, "Exact quadratic formula; negative discriminant, no real roots") }
            let square = try math.squareRoot(ExactNumber(discriminant)); let denominator = try F.multiply(Rational(2), p[2])
            let a = try math.scale(math.subtract(ExactNumber(F.negate(p[1])), square), F.divide(.one, denominator))
            let b = try math.scale(math.add(ExactNumber(F.negate(p[1])), square), F.divide(.one, denominator))
            let ordered = a == b ? [a] : try math.sign(math.subtract(a, b)) < 0 ? [a, b] : [b, a]
            let values = try ordered.filter(inside)
            for value in values {
                if !(try evaluateExact(p, value)).isZero { throw CalcError.arithmetic("Quadratic root substitution failed") }
            }
            return (values.map(exact), false, "Exact quadratic formula verified by substitution")
        }
        var sturm = try chain(p)
        if sturm[sturm.count - 1].count > 1 {
            let division = try dividePolynomial(p, sturm[sturm.count - 1])
            if !division.remainder.isEmpty { throw CalcError.arithmetic("Square-free polynomial verification failed") }
            p = division.quotient; sturm = try chain(p)
        }
        var bound = BigInt.one
        for c in p.dropLast() {
            let ratio = try F.divide(F.abs(c), F.abs(p[p.count - 1]))
            let ceiling = (ratio.numerator + ratio.denominator - 1) / ratio.denominator
            if ceiling >= bound { bound = ceiling + 1 }
        }
        var lo = try Rational(-bound), hi = try Rational(bound)
        if let dl = domainLo, F.compare(dl, lo) > 0 { lo = dl }
        if let dh = domainHi, F.compare(dh, hi) < 0 { hi = dh }
        if F.compare(lo, hi) > 0 { return ([], false, "Exact Cauchy root bound excludes the requested domain") }
        var roots: [EquationRoot] = []
        let expected = try variations(sturm, lo) - variations(sturm, hi)
        let lowRoot = try evaluate(p, lo).numerator.isZero
        if lowRoot { roots.append(exact(ExactNumber(lo))) }
        var cells: [Cell] = []
        if expected > 0 { cells.append((lo, hi, try variations(sturm, lo), try variations(sturm, hi))) }
        while let cell = cells.popLast() {
            try step()
            refinements += 1
            if refinements > 2048 { throw CalcError.arithmetic("Root isolation limit exceeded") }
            let count = cell.vLo - cell.vHi
            if count <= 0 { continue }
            if count == 1, try evaluate(p, cell.hi).numerator.isZero { roots.append(exact(ExactNumber(cell.hi))); continue }
            if count == 1, try EquationPolynomial.accurate(cell.lo, cell.hi) {
                let rational = try reconstruct(p, cell.lo, cell.hi)
                let estimate = FormulaNumbers.toDouble(try F.half(F.add(cell.lo, cell.hi)))
                if let r = rational { roots.append(exact(ExactNumber(r))) }
                else {
                    let value = NumericValue(try FormulaNumbers.fromDouble(estimate)).with { $0.isApproximate = true; $0.displayDecimalPlaces = FormulaNumbers.rootPlaces(estimate) }
                    roots.append(EquationRoot(value, cell.lo, cell.hi))
                }
                continue
            }
            let middle = try F.half(F.add(cell.lo, cell.hi)); let vm = try variations(sturm, middle)
            if vm < cell.vHi || vm > cell.vLo { throw CalcError.arithmetic("Sturm root-count verification failed") }
            if vm > cell.vHi { cells.append((middle, cell.hi, vm, cell.vHi)) }
            if cell.vLo > vm { cells.append((cell.lo, middle, cell.vLo, vm)) }
        }
        if roots.count != expected + (lowRoot ? 1 : 0) { throw CalcError.arithmetic("Root coverage verification failed") }
        // The roots are distinct, so any correct sort gives C#'s order.
        for i in 1..<max(1, roots.count) {
            var j = i
            while j > 0, try math.sign(math.subtract(roots[j].value.exact, roots[j - 1].value.exact)) < 0 { roots.swapAt(j, j - 1); j -= 1 }
        }
        return (roots, false, "Exact square-free Sturm count with disjoint rational isolation; rational roots reconstructed, others enclosed to 14 digits")
    }
}
