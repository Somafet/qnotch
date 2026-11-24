import Foundation

/// Deterministic, bounded primality and factorization. No randomness: Pollard rho uses fixed seeds, so results repeat exactly.
final class PrimeArithmetic {
    static let maxBits = 1024
    static let notNumeric = "Primality and factorization results are not numbers"
    private static let proven = "Deterministic Miller-Rabin with the first 13 prime bases, proven below 3317044064679887385961981 (Sorenson and Webster)"
    private static let probable = "13 Miller-Rabin bases plus a strong Lucas test (Baillie-PSW family); no counterexample is known, but this is not a proof"
    private static let factoring = "trial division below 1000, then deterministic Pollard rho within the computation budget"
    private static let rhoBudget = 8192, rhoBatch = 64, rhoPolynomials = 16
    private static let bases: [BigInt] = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41]
    private static let deterministicBound = BigInt("3317044064679887385961981")!
    private static let smallPrimes: [BigInt] = (2...999).filter { n in !(2..<n).prefix { $0 * $0 <= n }.contains { n % $0 == 0 } }.map { BigInt($0) }
    private let math: ExactArithmetic
    private let budget: ExecutionBudget
    private let token: CancellationToken
    private var rhoRemaining = 0
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) { self.math = math; self.budget = budget; self.token = token }
    static func isFunction(_ name: String) -> Bool { ["isprime", "factor", "nextprime", "prevprime"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws { if count != 1 { throw CalcError.format("\(name) expects 1 argument(s)") } }
    private func step() throws { try budget.step(token) }
    private func charge(_ steps: Int) throws { for _ in 0..<max(0, steps) { try step() } }
    /// C# IntegerArithmetic.IsExactInteger and Require (developer area), restated here so this area does not depend on that port.
    private static func exactInteger(_ value: SheetValue) throws -> BigInt? {
        if case .integer(let integer) = value { return integer.value }
        guard case .number(let number) = value, number.unit == nil, !number.isPercentage, !number.isApproximate, number.isRational else { return nil }
        let scalar = try number.scalar
        return scalar.denominator.isOne ? scalar.numerator : nil
    }
    private static func input(_ name: String, _ value: SheetValue) throws -> BigInt {
        guard let number = try exactInteger(value) else { throw CalcError.arithmetic(name + " expects an exact integer without units") }
        if number.sign < 0 { throw CalcError.arithmetic(name + " expects a nonnegative integer") }
        if number.bitLength > maxBits { throw CalcError.arithmetic(name + " supports integers below 2^1024") }
        return number
    }
    private func strongProbablePrime(_ n: BigInt, _ candidate: BigInt, _ odd: BigInt, _ twos: Int) throws -> Bool {
        let witness = candidate % n
        if witness.isZero { return true }
        let last = n - 1; try charge(1 + n.bitLength / 64)
        var x = BigInt.modPow(witness, odd, n)
        if x.isOne || x == last { return true }
        for _ in stride(from: 1, to: twos, by: 1) {
            try step(); x = x * x % n
            if x == last { return true }
            if x.isOne { return false }
        }
        return false
    }
    private func jacobi(_ a: BigInt, _ n: BigInt) throws -> Int {
        var a = a % n, n = n
        if a.sign < 0 { a += n }
        var result = 1
        while !a.isZero {
            try step()
            let twos = a.trailingZeroCount; a >>= twos
            if twos & 1 != 0 { let r = n % 8; if r == 3 || r == 5 { result = -result } }
            (a, n) = (n, a)
            if a % 4 == 3 && n % 4 == 3 { result = -result }
            a %= n
        }
        return n.isOne ? result : 0
    }
    /// Strong Lucas probable-prime test with Selfridge parameters (P = 1, Q = (1 - D)/4). n is odd and not a perfect square.
    private func strongLucas(_ n: BigInt) throws -> Bool {
        var d = BigInt(5)
        while try jacobi(d, n) != -1 { try step(); d = d.sign > 0 ? -(d + 2) : -d + 2 }
        let q = (1 - d) / 4; let twos = (n + 1).trailingZeroCount; let odd = (n + 1) >> twos
        func mod(_ value: BigInt) -> BigInt { let r = value % n; return r.sign < 0 ? r + n : r }
        func halve(_ value: BigInt) -> BigInt { (value.isEven ? value : value + n) >> 1 }
        var u = BigInt.one, v = BigInt.one, power = mod(q)
        var bit = odd.bitLength - 2
        while bit >= 0 {
            try step(); u = mod(u * v); v = mod(v * v - 2 * power); power = mod(power * power)
            if ((odd >> bit) & 1).isOne { (u, v) = (halve(mod(u + v)), halve(mod(d * u + v))); power = mod(power * q) }
            bit -= 1
        }
        if u.isZero { return true }
        for _ in 0..<twos {
            try step()
            if v.isZero { return true }
            v = mod(v * v - 2 * power); power = mod(power * power)
        }
        return false
    }
    private func isPrime(_ n: BigInt) throws -> Bool {
        if n < 2 { return false }
        for prime in PrimeArithmetic.smallPrimes {
            try step()
            if n == prime { return true }
            if (n % prime).isZero { return false }
        }
        if n < BigInt(1009 * 1009) { return true } // Below 1009^2 a survivor of trial division is prime.
        let twos = (n - 1).trailingZeroCount; let odd = (n - 1) >> twos
        for candidate in PrimeArithmetic.bases { if !(try strongProbablePrime(n, candidate, odd, twos)) { return false } }
        if n < PrimeArithmetic.deterministicBound { return true }
        let root = try math.integerRoot(n)
        return try root * root != n && strongLucas(n)
    }
    /// Pays for one batch of modular multiplications, scaled by operand size. False when the factoring allowance is gone.
    private func spend(_ n: BigInt) throws -> Bool {
        let steps = 1 + n.bitLength / 256
        rhoRemaining -= steps
        if rhoRemaining < 0 { return false }
        try charge(steps); return true
    }
    /// Brent's cycle variant of Pollard rho with fixed polynomials; nil when the budget ends without a split.
    private func rho(_ n: BigInt) throws -> BigInt? {
        for constant in 1...PrimeArithmetic.rhoPolynomials {
            let c = BigInt(constant)
            var y = BigInt(2), x = BigInt(2), saved = BigInt(2), product = BigInt.one, divisor = BigInt.one; var cycle = 1
            func next(_ value: BigInt) -> BigInt { (value * value + c) % n }
            repeat {
                x = y
                var done = 0
                while done < cycle {
                    if !(try spend(n)) { return nil }
                    for _ in 0..<min(PrimeArithmetic.rhoBatch, cycle - done) { y = next(y) }
                    done += PrimeArithmetic.rhoBatch
                }
                done = 0
                while done < cycle && divisor.isOne {
                    saved = y
                    if !(try spend(n)) { return nil }
                    for _ in 0..<min(PrimeArithmetic.rhoBatch, cycle - done) { y = next(y); product = product * (x - y).magnitude % n }
                    divisor = BigInt.gcd(product, n)
                    done += PrimeArithmetic.rhoBatch
                }
                cycle *= 2
            } while divisor.isOne
            if divisor == n {
                repeat { try step(); saved = next(saved); divisor = BigInt.gcd((x - saved).magnitude, n) } while divisor.isOne
            }
            if divisor != n { return divisor }
        }
        return nil
    }
    /// Prime powers in ascending order and the part that resisted factoring, 1 when complete.
    private func factorize(_ number: BigInt) throws -> (factors: [(prime: BigInt, count: Int)], cofactor: BigInt) {
        var n = number
        var factors: [BigInt: Int] = [:]; var cofactor = BigInt.one; rhoRemaining = PrimeArithmetic.rhoBudget
        func add(_ prime: BigInt) { factors[prime, default: 0] += 1 }
        func sorted() -> [(prime: BigInt, count: Int)] { factors.keys.sorted().map { ($0, factors[$0]!) } }
        for prime in PrimeArithmetic.smallPrimes {
            try step()
            while (n % prime).isZero { try step(); add(prime); n /= prime }
            if n.isOne { return (sorted(), cofactor) }
        }
        var pending = [n]
        while let part = pending.popLast() {
            try step()
            if part.isOne { continue }
            if try isPrime(part) { add(part); continue }
            let root = try math.integerRoot(part)
            if root * root == part { pending.append(root); pending.append(root); continue }
            if let divisor = try rho(part) { pending.append(divisor); pending.append(part / divisor) }
            else { cofactor *= part }
        }
        return (sorted(), cofactor)
    }
    private static func product(_ factors: [(prime: BigInt, count: Int)]) -> String {
        factors.map { $0.prime.description + ($0.count == 1 ? "" : "^" + String($0.count)) }.joined(separator: " × ")
    }
    private static func test(_ n: BigInt) -> String { n < deterministicBound ? proven : probable }
    private func isPrimeResult(_ n: BigInt) throws -> (value: SheetValue, evidence: String) {
        let prime = try isPrime(n); let proven = n < PrimeArithmetic.deterministicBound
        if prime { return (.prime(PrimeValue(n, true, proven, proven ? "prime" : "probable prime")), PrimeArithmetic.test(n)) }
        if n < 2 { return (.prime(PrimeValue(n, false, true, "not prime")), "0 and 1 are not prime by definition") }
        let (factors, cofactor) = try factorize(n); let complete = cofactor.isOne
        let evidence = PrimeArithmetic.test(n) + "; " + PrimeArithmetic.factoring + (complete ? "" : "; composite by the strong test, complete factorization exceeded the budget")
        return (.prime(PrimeValue(n, false, true, complete ? "not prime: " + PrimeArithmetic.product(factors) : "not prime")), evidence)
    }
    private func factorResult(_ n: BigInt) throws -> (value: SheetValue, evidence: String) {
        if n.isZero { throw CalcError.arithmetic("factor expects a positive integer") }
        if n.isOne { return (.prime(PrimeValue(n, false, true, "1")), "1 has no prime factors") }
        let (factors, cofactor) = try factorize(n)
        if !cofactor.isOne {
            throw CalcError.arithmetic("Factorization exceeded the computation budget" + (factors.isEmpty ? "" : "; found " + PrimeArithmetic.product(factors) + " and an unfactored composite"))
        }
        let proven = factors.allSatisfy { $0.prime < PrimeArithmetic.deterministicBound }
        return (.prime(PrimeValue(n, factors.count == 1 && factors[0].count == 1, proven, PrimeArithmetic.product(factors))),
                PrimeArithmetic.factoring + "; " + (proven ? PrimeArithmetic.proven : PrimeArithmetic.probable))
    }
    private func next(_ n: BigInt) throws -> (value: SheetValue, evidence: String) {
        if n < 2 { return (SheetValue(Rational(2)), PrimeArithmetic.proven) }
        var candidate = (n + 1) | 1
        while true {
            try step()
            if try isPrime(candidate) { return (SheetValue(try Rational(candidate)), PrimeArithmetic.test(candidate)) }
            candidate += 2
        }
    }
    private func previous(_ n: BigInt) throws -> (value: SheetValue, evidence: String) {
        if n <= 2 { throw CalcError.arithmetic("prevprime expects an integer above 2") }
        if n == 3 { return (SheetValue(Rational(2)), PrimeArithmetic.proven) }
        var candidate = (n - 2) | 1
        while true {
            try step()
            if try isPrime(candidate) { return (SheetValue(try Rational(candidate)), PrimeArithmetic.test(candidate)) }
            candidate -= 2
        }
    }
    func function(_ name: String, _ args: [SheetValue]) throws -> (value: SheetValue, evidence: String) {
        try PrimeArithmetic.validateArity(name, args.count)
        let n = try PrimeArithmetic.input(name, args[0])
        switch name.netLower {
        case "isprime": return try isPrimeResult(n)
        case "factor": return try factorResult(n)
        case "nextprime": return try next(n)
        default: return try previous(n)
        }
    }
}
