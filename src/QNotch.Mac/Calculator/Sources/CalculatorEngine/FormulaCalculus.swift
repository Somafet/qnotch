import Foundation

/// Symbolic differentiation over the formula AST with light constant folding and a bounded result size.
enum FormulaDerivative {
    private static let maxNodes = 4096
    static func differentiate(_ term: FormulaTerm, _ token: CancellationToken) throws -> FormulaTerm {
        var nodes = 0
        func made(_ node: FormulaTerm) throws -> FormulaTerm {
            try token.throwIfCancellationRequested()
            nodes += 1
            if nodes > maxNodes { throw CalcError.arithmetic("Derivative size limit exceeded") }
            return node
        }
        func isValue(_ node: FormulaTerm, _ value: Int) -> Bool { if case .literal(let literal) = node { return literal == Rational(value) }; return false }
        func literalValue(_ node: FormulaTerm) -> Rational? { if case .literal(let value) = node { return value }; return nil }
        func literal(_ value: Rational) throws -> FormulaTerm { try made(.literal(value)) }
        func add(_ a: FormulaTerm, _ b: FormulaTerm) throws -> FormulaTerm {
            if isValue(a, 0) { return b }
            if isValue(b, 0) { return a }
            if let x = literalValue(a), let y = literalValue(b) { return try literal(x + y) }
            return try made(.binary("+", a, b))
        }
        func sub(_ a: FormulaTerm, _ b: FormulaTerm) throws -> FormulaTerm {
            if isValue(b, 0) { return a }
            if isValue(a, 0) { return try neg(b) }
            if let x = literalValue(a), let y = literalValue(b) { return try literal(x - y) }
            return try made(.binary("-", a, b))
        }
        func mul(_ a: FormulaTerm, _ b: FormulaTerm) throws -> FormulaTerm {
            if isValue(a, 0) || isValue(b, 0) { return try literal(.zero) }
            if isValue(a, 1) { return b }
            if isValue(b, 1) { return a }
            if let x = literalValue(a), let y = literalValue(b) { return try literal(x * y) }
            return try made(.binary("*", a, b))
        }
        func div(_ a: FormulaTerm, _ b: FormulaTerm) throws -> FormulaTerm {
            if isValue(a, 0) || isValue(b, 1) { return a }
            return try made(.binary("/", a, b))
        }
        func pow(_ a: FormulaTerm, _ b: FormulaTerm) throws -> FormulaTerm {
            if isValue(b, 1) { return a }
            if isValue(b, 0) { return try literal(.one) }
            return try made(.binary("^", a, b))
        }
        func neg(_ a: FormulaTerm) throws -> FormulaTerm {
            if let x = literalValue(a) { return try literal(Rational(-1) * x) }
            if case .negate(let operand) = a { return operand }
            return try made(.negate(a))
        }
        func call(_ name: String, _ a: FormulaTerm) throws -> FormulaTerm { try made(.call(name, a)) }
        func one() throws -> FormulaTerm { try literal(.one) }
        func two() throws -> FormulaTerm { try literal(Rational(2)) }
        func d(_ node: FormulaTerm) throws -> FormulaTerm {
            switch node {
            case .variable: return try literal(.one)
            case .literal, .input, .constant: return try literal(.zero)
            case .negate(let operand): return try neg(try d(operand))
            case .binary("+", let left, let right): return try add(try d(left), try d(right))
            case .binary("-", let left, let right): return try sub(try d(left), try d(right))
            case .binary("*", let left, let right): return try add(try mul(try d(left), right), try mul(left, try d(right)))
            case .binary("/", let left, let right):
                return try div(try sub(try mul(try d(left), right), try mul(left, try d(right))), try pow(right, try two()))
            case .binary("^", let left, let right):
                if !FormulaFunctions.dependsOnVariable(right) {
                    return try mul(try mul(right, try pow(left, try sub(right, try one()))), try d(left))
                }
                // General power: u^v (v' ln u + v u'/u).
                return try mul(node, try add(try mul(try d(right), try call("ln", left)), try div(try mul(right, try d(left)), left)))
            case .call(let name, let u):
                let du = try d(u)
                let inner: FormulaTerm
                switch name {
                case "sin": inner = try call("cos", u)
                case "cos": inner = try neg(try call("sin", u))
                case "tan": inner = try div(try one(), try pow(try call("cos", u), try two()))
                case "asin": inner = try div(try one(), try call("sqrt", try sub(try one(), try pow(u, try two()))))
                case "acos": inner = try neg(try div(try one(), try call("sqrt", try sub(try one(), try pow(u, try two())))))
                case "atan": inner = try div(try one(), try add(try one(), try pow(u, try two())))
                case "sinh": inner = try call("cosh", u)
                case "cosh": inner = try call("sinh", u)
                case "tanh": inner = try div(try one(), try pow(try call("cosh", u), try two()))
                case "exp": inner = node
                case "ln": inner = try div(try one(), u)
                case "log": inner = try div(try one(), try mul(u, try call("ln", try literal(Rational(10)))))
                case "sqrt": inner = try div(try one(), try mul(try two(), node))
                case "abs": inner = try div(u, node)
                default: throw CalcError.format("Unknown formula function: \(name)")
                }
                return try mul(inner, du)
            default: throw CalcError.format("Unknown formula term")
            }
        }
        return try d(term)
    }
}

/// Exact rational coefficient extraction when the formula is a polynomial in the variable; nil otherwise.
enum FormulaPolynomial {
    static let maxDegree = 16
    static func tryExtract(_ term: FormulaTerm, _ inputs: [Rational?], _ math: EquationPolynomial, _ token: CancellationToken) throws -> [Rational]? {
        func walk(_ node: FormulaTerm) throws -> [Rational]? {
            try token.throwIfCancellationRequested()
            switch node {
            case .literal(let value): return math.trim([value])
            case .variable: return [.zero, .one]
            case .input(let index): return inputs[index].map { math.trim([$0]) }
            case .constant: return nil
            case .negate(let operand): return try walk(operand).map { try math.scale($0, Rational(-1)) }
            case .call: return nil
            case .binary(let operation, let leftNode, let rightNode):
                guard let left = try walk(leftNode) else { return nil }
                guard let right = try walk(rightNode) else { return nil }
                switch operation {
                case "+": return try math.sum(left, right)
                case "-": return try math.sum(left, right, subtract: true)
                case "*": return left.count + right.count - 2 > maxDegree ? nil : try math.product(left, right)
                case "/":
                    if right.count == 1 { return try math.scale(left, try Rational.one / right[0]) }
                    if right.isEmpty { throw CalcError.arithmetic("Division by zero in formula") }
                    return nil
                case "^":
                    if right.count > 1 || right.count == 1 && (!right[0].denominator.isOne || right[0].numerator.sign < 0) { return nil }
                    if left.count == 1 { return try constantPower(left[0], right.isEmpty ? .zero : right[0].numerator) }
                    // A variable base of degree >= 1 exceeds maxDegree at exponent maxDegree + 1, so the clamp only feeds the guard.
                    let exponent = right.isEmpty ? 0 : (right[0].numerator < BigInt(maxDegree + 1) ? right[0].numerator.intValue! : maxDegree + 1)
                    return (left.count - 1) * exponent > maxDegree ? nil : try math.power(left, exponent)
                default: throw CalcError.format("Unknown formula operator")
                }
            }
        }
        return try walk(term)
    }
    // Exact constant power with the true exponent; beyond the 4096-bit rational bound the formula takes the numeric path.
    private static func constantPower(_ value: Rational, _ exponent: BigInt) throws -> [Rational]? {
        if exponent.isZero { return [.one] }
        let bits = max(value.numerator.magnitude.bitLength, value.denominator.bitLength)
        if bits > 1 && exponent * BigInt(bits) > BigInt(4096) { return nil }
        if value.numerator.magnitude.isOne && value.denominator.isOne { return [Rational(value.numerator.sign < 0 && !exponent.isEven ? -1 : 1)] }
        // C# (int)exponent: bits <= 1 here means a zero base, whose huge exponent overflows the conversion.
        guard let power = exponent.intValue, power <= Int(Int32.max) else { throw CalcError.arithmetic(CalcError.overflowInt32Message) }
        return [try Rational(BigInt.pow(value.numerator, power), BigInt.pow(value.denominator, power))]
    }
}

/// Adaptive Gauss-Kronrod 7/15 integration with a QUADPACK-style error estimate and a subdivision bound.
enum FormulaIntegration {
    private static let nodes: [Double] = [0.991455371120812639206854697526329, 0.949107912342758524526189684047851, 0.864864423359769072789712788640926, 0.741531185599394439863864773280788,
        0.586087235467691130294144838258730, 0.405845151377397166906606412076961, 0.207784955007898467600689403773245, 0]
    private static let kronrodWeights: [Double] = [0.022935322010529224963732008058970, 0.063092092629978553290700663189204, 0.104790010322250183839876322541518, 0.140653259715525918745189590510238,
        0.169004726639267902826583426598550, 0.190350578064785409913256402421014, 0.204432940075298892414161999234649, 0.209482141084727828012999174891714]
    private static let gaussWeights: [Double] = [0.129484966168869693270611432679082, 0.279705391489276667901467771423780, 0.381830050505118944950369775488975, 0.417959183673469387755102040816327]
    static let maxIntervals = 512
    static let absoluteTolerance = 1e-12, relativeTolerance = 1e-10
    private typealias Interval = (a: Double, b: Double, value: Double, error: Double)

    static func integrate(_ formula: Formula, _ lower: Double, _ upper: Double, _ budget: ExecutionBudget, _ token: CancellationToken) throws -> (value: Double, error: Double, intervals: Int) {
        var lower = lower, upper = upper
        if !lower.isFinite || !upper.isFinite { throw CalcError.arithmetic("Integration bounds must be finite numbers") }
        if lower == upper { return (0, 0, 0) }
        var sign = 1.0
        if lower > upper { swap(&lower, &upper); sign = -1 }
        var intervals: [Interval] = [try rule(formula, lower, upper, budget, token)]
        while true {
            var total = 0.0, error = 0.0, worst = 0
            for i in 0..<intervals.count {
                total += intervals[i].value; error += intervals[i].error
                if intervals[i].error > intervals[worst].error { worst = i }
            }
            if error <= max(absoluteTolerance, relativeTolerance * Swift.abs(total)) { return (sign * total, error, intervals.count) }
            if intervals.count >= maxIntervals {
                throw CalcError.arithmetic("Integral did not converge within \(maxIntervals) subintervals; the integrand may be singular or oscillate rapidly")
            }
            let (a, b, _, _) = intervals[worst]; let middle = (a + b) / 2
            if middle <= a || middle >= b { throw CalcError.arithmetic("Integral did not converge; the integrand may be singular") }
            intervals[worst] = try rule(formula, a, middle, budget, token); intervals.append(try rule(formula, middle, b, budget, token))
        }
    }
    private static func rule(_ formula: Formula, _ a: Double, _ b: Double, _ budget: ExecutionBudget, _ token: CancellationToken) throws -> Interval {
        let center = (a + b) / 2, half = (b - a) / 2
        let centerValue = try sample(formula, center, budget, token)
        var kronrod = centerValue * kronrodWeights[7], gauss = centerValue * gaussWeights[3]
        var values = [Double](repeating: 0, count: 7), mirrored = [Double](repeating: 0, count: 7)
        for j in 0..<7 {
            let offset = half * nodes[j]
            values[j] = try sample(formula, center - offset, budget, token); mirrored[j] = try sample(formula, center + offset, budget, token)
            kronrod += kronrodWeights[j] * (values[j] + mirrored[j])
            if j & 1 == 1 { gauss += gaussWeights[j / 2] * (values[j] + mirrored[j]) }
        }
        let mean = kronrod / 2
        var spread = kronrodWeights[7] * Swift.abs(centerValue - mean)
        for j in 0..<7 { spread += kronrodWeights[j] * (Swift.abs(values[j] - mean) + Swift.abs(mirrored[j] - mean)) }
        spread *= half
        var error = Swift.abs((kronrod - gauss) * half)
        if spread != 0 && error != 0 { error = spread * min(1, Foundation.pow(200 * error / spread, 1.5)) }
        return (a, b, kronrod * half, error)
    }
    private static func sample(_ formula: Formula, _ x: Double, _ budget: ExecutionBudget, _ token: CancellationToken) throws -> Double {
        let value = try formula.sample(x, budget, token)
        if !value.isFinite { throw CalcError.arithmetic("Integrand is undefined or infinite at " + (try FormulaNumbers.fromDouble(x, 6)).description + "; the integral is not computed") }
        return value
    }
}

/// Bounded sign-change scan with bisection refinement. Finds bracketed simple roots only; no completeness claim.
enum FormulaRoots {
    static let samples = 2000, maxRoots = 16, bisections = 100
    static let defaultLower = -10.0, defaultUpper = 10.0
    static func scan(_ formula: Formula, _ lower: Double, _ upper: Double, _ budget: ExecutionBudget, _ token: CancellationToken) throws -> (roots: [Double], truncated: Bool) {
        if !lower.isFinite || !upper.isFinite || lower >= upper { throw CalcError.arithmetic("Search domain must be finite with lower < upper") }
        var roots: [Double] = []; var truncated = false
        let step = (upper - lower) / Double(samples)
        var previousX = lower; var previous = try formula.sample(lower, budget, token)
        if previous == 0 { roots.append(lower) }
        for i in 1...samples {
            let x = i == samples ? upper : lower + Double(i) * step
            let value = try formula.sample(x, budget, token)
            if value.isFinite && previous.isFinite {
                if value == 0 { keep(&roots, x, &truncated) }
                else if previous != 0 && netSign(value) != netSign(previous) {
                    if roots.count >= maxRoots { truncated = true } // Further brackets are reported, not refined, so the budget stays bounded.
                    else if let root = try refine(formula, previousX, x, previous, value, budget, token) { keep(&roots, root, &truncated) }
                }
            }
            previousX = x; previous = value
        }
        return (roots, truncated)
    }
    /// Math.Sign for finite doubles.
    private static func netSign(_ value: Double) -> Int { value > 0 ? 1 : value < 0 ? -1 : 0 }
    private static func keep(_ roots: inout [Double], _ root: Double, _ truncated: inout Bool) {
        if let last = roots.last, Swift.abs(last - root) <= 1e-9 * max(1, Swift.abs(root)) { return }
        if roots.count >= maxRoots { truncated = true; return }
        roots.append(root)
    }
    private static func refine(_ formula: Formula, _ a: Double, _ b: Double, _ fa: Double, _ fb: Double, _ budget: ExecutionBudget, _ token: CancellationToken) throws -> Double? {
        var a = a, b = b, fa = fa
        let scale = max(1, max(Swift.abs(fa), Swift.abs(fb)))
        for _ in 0..<bisections {
            let middle = (a + b) / 2
            if middle <= a || middle >= b { break }
            let fm = try formula.sample(middle, budget, token)
            if !fm.isFinite { return nil }
            if fm == 0 { return middle }
            if netSign(fm) == netSign(fa) { a = middle; fa = fm } else { b = middle }
            if b - a <= 1e-15 * max(1, Swift.abs(middle)) { break }
        }
        let root = (a + b) / 2; let residual = try formula.sample(root, budget, token)
        // A discontinuity such as a tan pole also changes sign; only a small residual is a root.
        return residual.isFinite && Swift.abs(residual) <= 1e-6 * scale ? root : nil
    }
}
