import Foundation

/// One isolated root as a rate interval [lowerRate, upperRate]; `exact` when both ends are the root itself.
struct IrrRootInterval: Hashable {
    let lowerRate: Rational, upperRate: Rational, exact: Bool
    init(_ lowerRate: Rational, _ upperRate: Rational, _ exact: Bool) { self.lowerRate = lowerRate; self.upperRate = upperRate; self.exact = exact }
}
/// The certificate behind an IRR result: every admissible root (ascending rate), which one the guess selected, and how.
struct IrrEvidence: Hashable {
    let distinctRoots: Int
    let guess: Rational
    let roots: [IrrRootInterval]
    let selectedRoot: Int
    let refinements: Int
    let method: String
    var inputApproximate: Bool
    let toleranceTie: Bool
}
struct IrrSolution { let rate: Rational, evidence: IrrEvidence }

/// Positive-discount roots of the represented cash-flow polynomial, without floating-point sign guesses.
/// Cash flow i is the coefficient of q^i with discount q = 1/(1+rate); a rate > -100% is a root q > 0.
final class IrrSolver {
    private static let maxCoefficients = 16384, maxVisits = 262144, maxValueBits = 16384
    private let budget: ExecutionBudget, token: CancellationToken
    private var visits = 0, refinements = 0
    init(_ budget: ExecutionBudget, _ token: CancellationToken) { self.budget = budget; self.token = token }

    /// A discount interval (lo, hi] with the Sturm variation counts at both ends; `upperRoot` when hi itself is a root.
    private struct Cell { let lo: Rational, hi: Rational, vLo: Int, vHi: Int; var upperRoot = false }
    private func step() throws { try budget.step(token) }
    private func visit() throws {
        visits += 1
        if visits > IrrSolver.maxVisits { throw CalcError.arithmetic("IRR coefficient-work limit exceeded") }
        if visits & 15 == 0 { try step() }
    }
    private func refineStep() throws {
        try step(); refinements += 1
        if refinements > 8192 { throw CalcError.arithmetic("IRR isolation limit exceeded") }
    }
    private static func fraction(_ n: BigInt, _ d: BigInt) throws -> Rational {
        if d.isZero { throw CalcError.arithmetic("Undefined IRR fraction") }
        let common = BigInt.gcd(n, d)
        return try Rational(n / common, d / common)
    }
    private static func add(_ a: Rational, _ b: Rational) throws -> Rational { try fraction(a.numerator * b.denominator + b.numerator * a.denominator, a.denominator * b.denominator) }
    private static func subtract(_ a: Rational, _ b: Rational) throws -> Rational { try fraction(a.numerator * b.denominator - b.numerator * a.denominator, a.denominator * b.denominator) }
    private static func half(_ a: Rational) throws -> Rational { try fraction(a.numerator, a.denominator * 2) }
    private static func compare(_ a: Rational, _ b: Rational) -> Int { BigInt.compare(a.numerator * b.denominator, b.numerator * a.denominator).signum() }
    private static func rate(_ discount: Rational) throws -> Rational { try fraction(discount.denominator - discount.numerator, discount.numerator) }
    private static func discount(_ rate: Rational) throws -> Rational { try fraction(rate.denominator, rate.denominator + rate.numerator) }
    private static func midRate(_ root: IrrRootInterval) throws -> Rational { try half(try add(root.lowerRate, root.upperRate)) }

    /// Drops trailing zero coefficients and divides by the positive content; Sturm signs are unchanged.
    private func primitive(_ polynomial: [BigInt]) throws -> [BigInt] {
        var length = polynomial.count
        while length > 0 && polynomial[length - 1].isZero { length -= 1 }
        if length == 0 { return [] }
        var common = BigInt.zero
        for i in 0..<length { try step(); common = BigInt.gcd(common, polynomial[i].magnitude) }
        var result = [BigInt](repeating: .zero, count: length)
        for i in 0..<length {
            try step(); result[i] = polynomial[i] / common
            if result[i].bitLength > 4096 { throw CalcError.arithmetic("IRR polynomial precision limit exceeded") }
        }
        return result
    }
    private func polynomial(_ flows: [Rational]) throws -> [BigInt] {
        var denominator = BigInt.one
        for value in flows {
            try step(); denominator = denominator / BigInt.gcd(denominator, value.denominator) * value.denominator
            if denominator.bitLength > 4096 { throw CalcError.arithmetic("IRR common-denominator limit exceeded") }
        }
        var coefficients = [BigInt](repeating: .zero, count: flows.count)
        for i in 0..<flows.count { try step(); coefficients[i] = flows[i].numerator * (denominator / flows[i].denominator) }
        var start = 0; while start < coefficients.count && coefficients[start].isZero { start += 1 }
        return try primitive(Array(coefficients[start...])) // A common q^k changes no positive-discount root.
    }
    private func derivative(_ polynomial: [BigInt]) throws -> [BigInt] {
        var result = [BigInt](repeating: .zero, count: polynomial.count - 1)
        for i in 1..<max(1, polynomial.count) { try step(); result[i - 1] = polynomial[i] * BigInt(i) }
        return try primitive(result)
    }
    /// Pseudo-remainder with positive scaling, so signs follow the true remainder.
    private func remainder(_ dividend: [BigInt], _ divisor: [BigInt]) throws -> [BigInt] {
        var remainder = dividend
        let leading = divisor[divisor.count - 1].magnitude, sign = BigInt(divisor[divisor.count - 1].sign)
        while remainder.count >= divisor.count {
            try step(); let shift = remainder.count - divisor.count; let coefficient = remainder[remainder.count - 1]
            for i in 0..<remainder.count { try step(); remainder[i] *= leading }
            for i in 0..<divisor.count { try step(); remainder[i + shift] -= coefficient * sign * divisor[i] }
            remainder = try primitive(remainder)
        }
        return remainder
    }
    private func chain(_ polynomial: [BigInt]) throws -> [[BigInt]] {
        var chain = [polynomial, try derivative(polynomial)]
        var stored = chain.reduce(0) { $0 + $1.count }
        while chain[chain.count - 1].count > 1 {
            var remainder = try self.remainder(chain[chain.count - 2], chain[chain.count - 1])
            if remainder.isEmpty { break }
            for i in 0..<remainder.count { remainder[i] = -remainder[i] }
            stored += remainder.count
            if stored > IrrSolver.maxCoefficients { throw CalcError.arithmetic("IRR polynomial-storage limit exceeded") }
            chain.append(remainder)
        }
        return chain
    }
    private func quotient(_ polynomial: [BigInt], _ factor: [BigInt]) throws -> [BigInt] {
        var remainder = polynomial; var result = [BigInt](repeating: .zero, count: polynomial.count - factor.count + 1)
        for shift in stride(from: result.count - 1, through: 0, by: -1) {
            try step()
            let division = remainder[shift + factor.count - 1].quotientAndRemainder(dividingBy: factor[factor.count - 1])
            if !division.remainder.isZero { throw CalcError.arithmetic("IRR exact factorization failed") }
            result[shift] = division.quotient
            for i in 0..<factor.count { try step(); remainder[i + shift] -= division.quotient * factor[i] }
        }
        if remainder.contains(where: { !$0.isZero }) { throw CalcError.arithmetic("IRR exact factorization failed") }
        return try primitive(result)
    }
    private static func floor(_ value: BigInt, _ denominator: BigInt) -> BigInt {
        let division = value.quotientAndRemainder(dividingBy: denominator)
        return value.sign < 0 && !division.remainder.isZero ? division.quotient - 1 : division.quotient
    }
    private static func ceiling(_ value: BigInt, _ denominator: BigInt) -> BigInt {
        let division = value.quotientAndRemainder(dividingBy: denominator)
        return value.sign > 0 && !division.remainder.isZero ? division.quotient + 1 : division.quotient
    }
    private static func range(_ value: BigInt) throws {
        if value.bitLength > maxValueBits { throw CalcError.arithmetic("IRR sign-evaluation range limit exceeded") }
    }
    private func sign(_ polynomial: [BigInt], _ at: Rational) throws -> Int {
        // Directed integer rounding encloses exact Horner values at a positive rational endpoint.
        var bits = 128
        while bits <= 1024 {
            let scale = BigInt.one << bits
            var lower = polynomial[polynomial.count - 1] * scale; var upper = lower
            for i in stride(from: polynomial.count - 2, through: 0, by: -1) {
                try visit(); let term = polynomial[i] * scale
                lower = IrrSolver.floor(lower * at.numerator, at.denominator) + term
                upper = IrrSolver.ceiling(upper * at.numerator, at.denominator) + term
                try IrrSolver.range(lower); try IrrSolver.range(upper)
            }
            if lower.sign > 0 { return 1 }
            if upper.sign < 0 { return -1 }
            if lower.isZero && upper.isZero { return 0 }
            bits *= 2
        }
        // An exact rational hit must not be mistaken for a tiny residual. Bound the homogeneous fallback.
        var value = polynomial[polynomial.count - 1]; var power = BigInt.one
        for i in stride(from: polynomial.count - 2, through: 0, by: -1) {
            try visit(); power *= at.denominator; try IrrSolver.range(power)
            value = value * at.numerator + polynomial[i] * power; try IrrSolver.range(value)
        }
        return value.sign
    }
    private static func variations(_ signs: [Int]) -> Int {
        var previous = 0, result = 0
        for sign in signs where sign != 0 {
            if previous != 0 && previous != sign { result += 1 }
            previous = sign
        }
        return result
    }
    private func at(_ chain: [[BigInt]], _ point: Rational) throws -> (variations: Int, root: Bool) {
        var signs = [Int](repeating: 0, count: chain.count)
        for i in 0..<signs.count { signs[i] = try sign(chain[i], point) }
        return (IrrSolver.variations(signs), signs[0] == 0)
    }
    /// Cauchy bounds on the positive roots q of the polynomial and of its reverse.
    private func bounds(_ polynomial: [BigInt]) throws -> (lower: Rational, upper: Rational) {
        var upperRatio = Rational.zero, reverseRatio = Rational.zero
        let last = polynomial.count - 1
        for i in 0..<polynomial.count {
            try step()
            if i < last {
                let ratio = try IrrSolver.fraction(polynomial[i].magnitude, polynomial[last].magnitude)
                if IrrSolver.compare(ratio, upperRatio) > 0 { upperRatio = ratio }
            }
            if i > 0 {
                let ratio = try IrrSolver.fraction(polynomial[i].magnitude, polynomial[0].magnitude)
                if IrrSolver.compare(ratio, reverseRatio) > 0 { reverseRatio = ratio }
            }
        }
        let reverse = try IrrSolver.add(.one, reverseRatio)
        return (try IrrSolver.fraction(reverse.denominator, reverse.numerator), try IrrSolver.add(.one, upperRatio))
    }
    private static func log2(_ value: Rational) -> Int {
        var exponent = value.numerator.bitLength - value.denominator.bitLength
        if exponent >= 0 ? value.numerator < value.denominator << exponent : value.numerator << -exponent < value.denominator { exponent -= 1 }
        return exponent
    }
    /// A power of two between the ends when they span several binades (geometric bisection), else the arithmetic mean.
    private static func midpoint(_ lower: Rational, _ upper: Rational) throws -> Rational {
        let lo = log2(lower), hi = log2(upper)
        if hi - lo > 2 {
            let exponent = lo + (hi - lo) / 2
            let dyadic = exponent >= 0 ? try Rational(BigInt.one << exponent, .one) : try Rational(.one, BigInt.one << -exponent)
            if compare(dyadic, lower) > 0 && compare(dyadic, upper) < 0 { return dyadic }
        }
        return try half(try add(lower, upper))
    }
    private func rounded(_ rate: Rational) throws -> Rational {
        try ExactRounding.apply(.decimalPlaces, NumericValue(rate, isPercentage: true), NumericValue(Rational(4)), token).scalar
    }
    private static func accurate(_ lowerRate: Rational, _ upperRate: Rational) throws -> Bool {
        let width = try subtract(upperRate, lowerRate); let middle = (try half(try add(lowerRate, upperRate))).abs
        let tolerance = compare(middle, .one) > 0 ? middle : .one
        return width.numerator * tolerance.denominator * BigInt.pow(10, 14) <= tolerance.numerator * width.denominator
    }
    private func refine(_ cell: Cell, _ polynomial: [BigInt], _ chain: [[BigInt]]?, _ guess: Rational) throws -> IrrRootInterval {
        var lower = cell.lo, upper = cell.hi, vLower = cell.vLo
        if cell.upperRoot { let root = try IrrSolver.rate(upper); return IrrRootInterval(root, root, true) }
        for candidate in [try IrrSolver.discount(guess), Rational.one]
        where try IrrSolver.compare(candidate, lower) > 0 && IrrSolver.compare(candidate, upper) <= 0 && sign(polynomial, candidate) == 0 {
            let root = try IrrSolver.rate(candidate); return IrrRootInterval(root, root, true)
        }
        let lowerSign = polynomial[0].sign
        for _ in 0..<256 {
            try refineStep(); let rateLower = try IrrSolver.rate(upper); let rateUpper = try IrrSolver.rate(lower)
            if try IrrSolver.accurate(rateLower, rateUpper) {
                // Stop once both ends round to the same four-decimal percentage, or the halfway boundary is the root.
                let roundedLower = try rounded(rateLower); let roundedUpper = try rounded(rateUpper)
                if roundedLower == roundedUpper { return IrrRootInterval(rateLower, rateUpper, false) }
                let boundary = try IrrSolver.half(try IrrSolver.add(roundedLower, roundedUpper))
                if try IrrSolver.compare(boundary, rateLower) >= 0 && IrrSolver.compare(boundary, rateUpper) < 0 && sign(polynomial, IrrSolver.discount(boundary)) == 0 {
                    return IrrRootInterval(boundary, boundary, true)
                }
            }
            let middle = try IrrSolver.midpoint(lower, upper)
            if let chain {
                let (variation, root) = try at(chain, middle)
                if root { let exact = try IrrSolver.rate(middle); return IrrRootInterval(exact, exact, true) }
                if vLower - variation == 1 { upper = middle } else { lower = middle; vLower = variation }
            } else {
                let sign = try self.sign(polynomial, middle)
                if sign == 0 { let root = try IrrSolver.rate(middle); return IrrRootInterval(root, root, true) }
                if sign == lowerSign { lower = middle } else { upper = middle }
            }
        }
        throw CalcError.arithmetic("IRR refinement did not converge within 256 steps")
    }
    func solve(_ cash: [Rational], _ guess: Rational) throws -> IrrSolution {
        if cash.count < 2 { throw CalcError.arithmetic("IRR requires at least two cash flows") }
        if cash.allSatisfy({ $0.isZero }) { throw CalcError.arithmetic("IRR is indeterminate for all-zero cash flows") }
        if !cash.contains(where: { $0.sign > 0 }) || !cash.contains(where: { $0.sign < 0 }) { throw CalcError.arithmetic("IRR requires both positive and negative cash flows") }
        var polynomial = try self.polynomial(cash)
        var roots: [IrrRootInterval] = []; let method: String
        if polynomial.count == 2 {
            let discount = try IrrSolver.fraction(-polynomial[0], polynomial[1])
            if discount.sign <= 0 { throw CalcError.arithmetic("No admissible IRR with rate greater than -100%") }
            let rate = try IrrSolver.rate(discount); roots.append(IrrRootInterval(rate, rate, true)); method = "Exact linear cash-flow root"
        } else if IrrSolver.variations(polynomial.map(\.sign)) == 1 {
            let bounds = try self.bounds(polynomial)
            roots.append(try refine(Cell(lo: bounds.lower, hi: bounds.upper, vLo: 1, vHi: 0), polynomial, nil, guess))
            method = "Descartes unique positive-discount root; directed sign enclosures"
        } else {
            var chain = try self.chain(polynomial)
            if chain[chain.count - 1].count > 1 { polynomial = try quotient(polynomial, chain[chain.count - 1]); chain = try self.chain(polynomial) }
            let vZero = IrrSolver.variations(chain.map { $0.first(where: { !$0.isZero })!.sign })
            let vInfinity = IrrSolver.variations(chain.map { $0[$0.count - 1].sign })
            if vZero < vInfinity { throw CalcError.arithmetic("IRR root-count verification failed") }
            if vZero == vInfinity { throw CalcError.arithmetic("No admissible IRR with rate greater than -100%") }
            let bounds = try self.bounds(polynomial)
            var cells = [Cell(lo: bounds.lower, hi: bounds.upper, vLo: vZero, vHi: vInfinity)] // a stack: last in, first out
            while let cell = cells.popLast() {
                let count = cell.vLo - cell.vHi
                if count == 1 { roots.append(try refine(cell, polynomial, chain, guess)); continue }
                try refineStep(); let midpoint = try IrrSolver.midpoint(cell.lo, cell.hi); let (variation, root) = try at(chain, midpoint)
                if variation < cell.vHi || variation > cell.vLo { throw CalcError.arithmetic("IRR isolation-count verification failed") }
                if variation - cell.vHi > 0 { cells.append(Cell(lo: midpoint, hi: cell.hi, vLo: variation, vHi: cell.vHi, upperRoot: cell.upperRoot)) }
                if cell.vLo - variation > 0 { cells.append(Cell(lo: cell.lo, hi: midpoint, vLo: cell.vLo, vHi: variation, upperRoot: root)) }
            }
            roots.reverse() // Positive discount order is the reverse of rate order.
            method = "Square-free Sturm isolation of all distinct positive-discount roots"
        }
        var selected = 0, tie = false
        var distance = (try IrrSolver.subtract(try IrrSolver.midRate(roots[0]), guess)).abs
        for i in 1..<max(1, roots.count) {
            try step(); let candidate = (try IrrSolver.subtract(try IrrSolver.midRate(roots[i]), guess)).abs
            let difference = (try IrrSolver.subtract(candidate, distance)).abs; let scale = IrrSolver.compare(distance, .one) > 0 ? distance : .one
            let close = difference.numerator * scale.denominator * BigInt.pow(10, 12) <= scale.numerator * difference.denominator
            if close { tie = true; continue } // Ascending rates: lower rate wins a tolerance tie.
            if IrrSolver.compare(candidate, distance) < 0 { selected = i; distance = candidate; tie = false }
        }
        return IrrSolution(rate: try IrrSolver.midRate(roots[selected]),
                           evidence: IrrEvidence(distinctRoots: roots.count, guess: guess, roots: roots, selectedRoot: selected, refinements: refinements, method: method, inputApproximate: false, toleranceTie: tie))
    }
}
