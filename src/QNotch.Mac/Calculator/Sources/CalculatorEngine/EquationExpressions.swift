import Foundation

final class EquationExpression: Expression {
    let variable: String, left: FormulaTerm, right: FormulaTerm, inputs: [Expression], hasDomain: Bool
    init(_ variable: String, _ left: FormulaTerm, _ right: FormulaTerm, _ inputs: [Expression], _ hasDomain: Bool) {
        self.variable = variable; self.left = left; self.right = right; self.inputs = inputs; self.hasDomain = hasDomain
    }
    var children: [Expression] { inputs }
}
final class IntegralExpression: Expression {
    let variable: String, body: FormulaTerm, inputs: [Expression]
    init(_ variable: String, _ body: FormulaTerm, _ inputs: [Expression]) { self.variable = variable; self.body = body; self.inputs = inputs }
    var children: [Expression] { inputs }
}
final class DerivativeExpression: Expression {
    let variable: String, body: FormulaTerm, inputs: [Expression]
    init(_ variable: String, _ body: FormulaTerm, _ inputs: [Expression]) { self.variable = variable; self.body = body; self.inputs = inputs }
    var children: [Expression] { inputs }
}
// ConstantExpression lives with the core expression nodes (Core/Expressions.swift).

/// solve left = right [for name] [from lower to upper]; either tail order. A sheet variable named solve disables the sentence.
enum EquationSyntax {
    static func prefix(_ text: String) -> Bool {
        let u = text.units
        return u.count > 6 && text.startsWithIgnoreCase("solve") && NetChar.isWhiteSpace(u[5]) && u.contains(0x3D) && !text.netSubstring(6).netTrimStart.hasPrefix("=")
    }
    static func function(_ name: String) -> Bool { ["solutionroot", "solutioncount"].contains(name.netLower) }
    static func arity(_ name: String) -> Int { name.equalsIgnoreCase("solutionRoot") ? 2 : 1 }
    static func sides(_ text: String) throws -> [String] {
        let sides = text.netSubstring(5).netSplit("=")
        if sides.count != 2 { throw CalcError.format("An equation requires exactly one equality") }
        return sides
    }
    static func parse(_ text: String, _ names: NetHashSet<String>?, _ token: CancellationToken) throws -> EquationExpression {
        let sides = try sides(text)
        let left = try ExpressionParser.tokenize(sides[0], token, names), right = try ExpressionParser.tokenize(sides[1], token, names)
        var variable = "x"; var from = -1, to = -1, forAt = -1, nesting = 0; let end = right.count
        for i in 0..<end {
            try token.throwIfCancellationRequested(); let t = right[i].text
            if t == "(" { nesting += 1 } else if t == ")" { nesting -= 1 }
            else if nesting == 0 && right[i].kind == .name {
                if t.equalsIgnoreCase("for") && forAt < 0 { forAt = i }
                else if t.equalsIgnoreCase("from") && from < 0 { from = i }
                else if t.equalsIgnoreCase("to") && from >= 0 && to < 0 { to = i }
            }
        }
        if nesting != 0 { throw CalcError.format("Unbalanced equation parentheses") }
        var formulaEnd: Int, domainEnd = end
        if forAt >= 0 {
            if forAt + 1 >= end || right[forAt + 1].kind != .name || !FunctionLibrary.validIdentifier(right[forAt + 1].text, 32) { throw CalcError.format("Use for followed by one variable name") }
            variable = right[forAt + 1].text
            if from < 0 {
                if forAt + 2 != end { throw CalcError.format("Use for followed by one variable name") }
                formulaEnd = forAt
            } else if forAt + 2 == from { formulaEnd = forAt }
            else if from < forAt && forAt + 2 == end { formulaEnd = from; domainEnd = forAt }
            else { throw CalcError.format("Use for name and from lower to upper after the equation") }
        } else { formulaEnd = from >= 0 ? from : end }
        if from >= 0 && (to <= from + 1 || to >= domainEnd - 1) { throw CalcError.format("Use from lower to upper after the equation") }
        var inputs = FormulaInputs()
        let leftTerm = try FormulaParser.parse(left, variable, &inputs, names, token)
        let rightTerm = try FormulaParser.parse(Array(right.prefix(formulaEnd)), variable, &inputs, names, token)
        if from >= 0 {
            inputs.expressions.append(try ExpressionParser(Array(right[(from + 1)..<to]), token, names).parse())
            inputs.expressions.append(try ExpressionParser(Array(right[(to + 1)..<domainEnd]), token, names).parse())
        }
        return EquationExpression(variable, leftTerm, rightTerm, inputs.expressions, from >= 0)
    }
}

enum CalculusSyntax {
    static func isFunction(_ name: String) -> Bool { ["integral", "derivative"].contains(name.netLower) }
    static func arity(_ name: String) -> Int { name.equalsIgnoreCase("integral") ? 3 : 2 }
}

extension ExpressionParser {
    /// integral(formula, lower, upper[, variable]) and derivative(formula, point[, variable]); the formula is parsed, not evaluated.
    func parseCalculus(_ name: String) throws -> Expression {
        let integral = name.equalsIgnoreCase("integral")
        var segments: [(start: Int, end: Int)] = []; var start = position; var nesting = 0
        while position < tokens.count {
            let text = tokens[position].text
            if text == "(" || text == "[" { nesting += 1 }
            else if text == ")" || text == "]" { if nesting == 0 { break }; nesting -= 1 }
            else if text == "," && nesting == 0 { segments.append((start, position)); start = position + 1 }
            position += 1
        }
        if position >= tokens.count { throw CalcError.format("Expected )") }
        segments.append((start, position)); position += 1
        let minimum = CalculusSyntax.arity(name)
        if segments.count < minimum || segments.count > minimum + 1 {
            throw CalcError.format(integral ? "integral expects (formula, lower, upper) with an optional variable name" : "derivative expects (formula, point) with an optional variable name")
        }
        var variable = "x"
        if segments.count > minimum {
            let (s, e) = segments[segments.count - 1]
            if e - s != 1 || tokens[s].kind != .name || !FunctionLibrary.validIdentifier(tokens[s].text, 32) { throw CalcError.format("Name the variable with one identifier as the last argument") }
            variable = tokens[s].text
        }
        var inputs = FormulaInputs()
        func slice(_ segment: (start: Int, end: Int)) -> [Token] { Array(tokens[segment.start..<segment.end]) }
        let body = try FormulaParser.parse(slice(segments[0]), variable, &inputs, knownNames, cancellationToken)
        for i in 1..<minimum { inputs.expressions.append(try ExpressionParser(slice(segments[i]), cancellationToken, knownNames, questionDepth + 1).parse()) }
        return integral ? IntegralExpression(variable, body, inputs.expressions) : DerivativeExpression(variable, body, inputs.expressions)
    }
}

/// Evaluates formula nodes: exact polynomial paths, numeric fallbacks marked approximate, and the sheet-level transcendental functions.
final class FormulaArithmetic {
    private let math: ExactArithmetic
    private let budget: ExecutionBudget
    private let token: CancellationToken
    private let polynomials: EquationPolynomial
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) {
        self.math = math; self.budget = budget; self.token = token; polynomials = EquationPolynomial(math, budget, token)
    }
    static func require(_ value: SheetValue, _ role: String) throws -> NumericValue {
        guard case .number(let number) = value, number.unit == nil else { throw CalcError.arithmetic(role + " must be a dimensionless number") }
        return number
    }
    static func prepare(_ term: FormulaTerm, _ variable: String, _ inputs: [SheetValue], _ count: Int) throws -> (formula: Formula, exact: [Rational?], approximate: Bool) {
        var doubles = [Double](repeating: 0, count: count), exact = [Rational?](repeating: nil, count: count), approximate = false
        for i in 0..<count {
            let number = try require(inputs[i], "Formula input \(i + 1)")
            doubles[i] = FormulaNumbers.toDouble(number.exact); exact[i] = number.exact.isRational ? number.exact.constant : nil
            approximate = approximate || number.isApproximate
        }
        return (Formula(term, variable, doubles), exact, approximate)
    }
    private static func approximate(_ value: Double, _ significant: Int = 12) throws -> NumericValue {
        NumericValue(try FormulaNumbers.fromDouble(value, significant)).with { $0.isApproximate = true }
    }
    private func rationalBound(_ value: NumericValue, _ lower: Bool) throws -> Rational {
        if value.exact.isRational { return value.exact.constant }
        let bounds = try math.bounds(value.exact, 64)
        return lower ? bounds.lower : bounds.upper
    }
    func solve(_ equation: EquationExpression, _ inputs: [SheetValue]) throws -> (value: SheetValue, assumption: String) {
        let constants = equation.inputs.count - (equation.hasDomain ? 2 : 0)
        let difference = FormulaTerm.binary("-", equation.left, equation.right)
        let (formula, exact, approximate) = try FormulaArithmetic.prepare(difference, equation.variable, inputs, constants)
        let lower = equation.hasDomain ? try FormulaArithmetic.require(inputs[inputs.count - 2], "Domain bound") : nil
        let upper = equation.hasDomain ? try FormulaArithmetic.require(inputs[inputs.count - 1], "Domain bound") : nil
        if let lo = lower, let hi = upper, try math.sign(math.subtract(hi.exact, lo.exact)) <= 0 { throw CalcError.arithmetic("Use from lower to upper with lower < upper") }
        if let polynomial = try FormulaPolynomial.tryExtract(difference, exact, polynomials, token) {
            let solved = try polynomials.solve(polynomial, try lower.map { try rationalBound($0, true) }, try upper.map { try rationalBound($0, false) })
            func inside(_ root: EquationRoot) throws -> Bool {
                if root.value.isApproximate {
                    let x = FormulaNumbers.toDouble(root.value.exact)
                    return (lower.map { x >= FormulaNumbers.toDouble($0.exact) } ?? true) && (upper.map { x <= FormulaNumbers.toDouble($0.exact) } ?? true)
                }
                return try (lower.map { try math.sign(math.subtract(root.value.exact, $0.exact)) >= 0 } ?? true) &&
                    (upper.map { try math.sign(math.subtract(root.value.exact, $0.exact)) <= 0 } ?? true)
            }
            let roots = try solved.roots.filter(inside).map { root in
                approximate ? EquationRoot(root.value.with {
                    $0.isApproximate = true; $0.displayDecimalPlaces = root.value.displayDecimalPlaces ?? FormulaNumbers.rootPlaces(FormulaNumbers.toDouble(root.value.exact))
                }, root.lower, root.upper) : root
            }
            let scope: EquationSolutionScope = solved.identity ? .identity : .allRealRoots
            let summary = solved.identity ? "Identity: every real value solves it" : "Exact: all distinct real roots" + (lower == nil ? "" : " in the stated domain") + "; complex roots out of scope"
            return (.equation(try EquationValue(equation.variable, roots, scope, solved.method, summary, inDomain: lower != nil)), "Polynomial equation; exact arithmetic; complex roots out of scope")
        }
        let a = lower.map { FormulaNumbers.toDouble($0.exact) } ?? FormulaRoots.defaultLower, b = upper.map { FormulaNumbers.toDouble($0.exact) } ?? FormulaRoots.defaultUpper
        let (found, truncated) = try FormulaRoots.scan(formula, a, b, budget, token)
        let window = "[" + (try FormulaNumbers.fromDouble(a, 6)).description + ", " + (try FormulaNumbers.fromDouble(b, 6)).description + "]"
        let method = "Sign-change scan of \(FormulaRoots.samples) samples on " + window + " with bisection refinement; " + FormulaFunctions.convention
        let numeric = try EquationValue(equation.variable, try found.map { root in EquationRoot(try FormulaArithmetic.approximate(root).with { $0.displayDecimalPlaces = FormulaNumbers.rootPlaces(root) }) }, .bracketedRoots, method,
            "Approximate: " + (found.isEmpty ? "no sign change found in " + window + ", not proof of no solution" : "\(found.count) bracketed root(s) in " + window + "; no completeness claim"), truncated: truncated)
        return (.equation(numeric), "Nonpolynomial equation; bracketed roots only, no completeness claim; " + FormulaFunctions.convention)
    }
    func integrate(_ integral: IntegralExpression, _ inputs: [SheetValue]) throws -> (value: SheetValue, assumption: String) {
        var (formula, exact, approximate) = try FormulaArithmetic.prepare(integral.body, integral.variable, inputs, inputs.count - 2)
        let lower = try FormulaArithmetic.require(inputs[inputs.count - 2], "Lower bound"), upper = try FormulaArithmetic.require(inputs[inputs.count - 1], "Upper bound")
        approximate = approximate || lower.isApproximate || upper.isApproximate
        if let polynomial = try FormulaPolynomial.tryExtract(integral.body, exact, polynomials, token) {
            let antiderivative = try polynomials.antiderivative(polynomial)
            let value = try math.subtract(polynomials.evaluateExact(antiderivative, upper.exact), polynomials.evaluateExact(antiderivative, lower.exact))
            return (.number(NumericValue(value).with { $0.isApproximate = approximate }), "Exact polynomial antiderivative evaluated at both bounds; dimensionless definite integral")
        }
        let (result, error, intervals) = try FormulaIntegration.integrate(formula, FormulaNumbers.toDouble(lower.exact), FormulaNumbers.toDouble(upper.exact), budget, token)
        let digits = error <= 0 ? 12 : Int(min(max(Foundation.floor(Foundation.log10(Swift.abs(result) / error)), 2), 12))
        let rounded = Swift.abs(result) <= FormulaIntegration.absoluteTolerance && error <= FormulaIntegration.absoluteTolerance ?
            NumericValue(Rational.zero).with { $0.isApproximate = true } : try FormulaArithmetic.approximate(result, digits)
        return (.number(rounded), "Adaptive Gauss-Kronrod 7/15 over \(intervals) subinterval(s), estimated error ≤ " + NetFormat.double(error, "0.#E+0") + "; " +
                FormulaFunctions.convention + "; infinite bounds and singularities unsupported")
    }
    func differentiate(_ derivative: DerivativeExpression, _ inputs: [SheetValue]) throws -> (value: SheetValue, assumption: String) {
        var (formula, exact, approximate) = try FormulaArithmetic.prepare(derivative.body, derivative.variable, inputs, inputs.count - 1)
        let point = try FormulaArithmetic.require(inputs[inputs.count - 1], "Derivative point"); approximate = approximate || point.isApproximate
        if let polynomial = try FormulaPolynomial.tryExtract(derivative.body, exact, polynomials, token) {
            let value = try polynomials.evaluateExact(polynomials.derivative(polynomial), point.exact)
            return (.number(NumericValue(value).with { $0.isApproximate = approximate }), "Exact polynomial derivative evaluated at the point")
        }
        let slope = try FormulaDerivative.differentiate(derivative.body, token)
        let value = try formula.with(slope).sample(FormulaNumbers.toDouble(point.exact), budget, token)
        if !value.isFinite { throw CalcError.arithmetic("Derivative is undefined at " + (try point.display)) }
        return (.number(try FormulaArithmetic.approximate(value)), "Symbolic derivative d/d" + derivative.variable + " = " + FormulaText.render(slope, derivative.variable) +
                ", evaluated at the point; " + FormulaFunctions.convention)
    }
    func sheetFunction(_ name: String, _ args: [SheetValue]) throws -> SheetValue {
        if args.count != 1 { throw CalcError.format(name + " expects 1 argument") }
        let argument = try FormulaArithmetic.require(args[0], name + " argument")
        let value = try FormulaFunctions.apply(name.netLower, FormulaNumbers.toDouble(argument.exact))
        if !value.isFinite { throw CalcError.arithmetic(name + " is undefined at " + (try argument.display)) }
        try budget.step(token); return .number(try FormulaArithmetic.approximate(value))
    }
    func solutionFunction(_ name: String, _ args: [SheetValue]) throws -> SheetValue {
        if args.count != EquationSyntax.arity(name) { throw CalcError.format(name + " expects \(EquationSyntax.arity(name)) argument(s)") }
        guard case .equation(let equation) = args[0] else { throw CalcError.arithmetic(name + " expects a solve result") }
        try budget.step(token)
        if equation.scope == .identity { throw CalcError.arithmetic("An identity has no finite root list") }
        if name.equalsIgnoreCase("solutionCount") { return SheetValue(Rational(equation.roots.count)) }
        let index = try FormulaArithmetic.require(args[1], "Root index").exact
        guard index.isRational, index.constant.denominator.isOne, index.constant.numerator >= BigInt(1), index.constant.numerator <= BigInt(equation.roots.count) else {
            throw CalcError.arithmetic("Root index must be a whole number from 1 to \(equation.roots.count)")
        }
        return .number(equation.roots[index.constant.numerator.intValue! - 1].value)
    }
}

/// Bounded readable rendering of a formula for explanations.
enum FormulaText {
    static func render(_ term: FormulaTerm, _ variable: String) -> String {
        let text = write(term, variable, 0)
        return text.netLength <= 200 ? text : text.netSubstring(0, 200) + "…"
    }
    private static func write(_ node: FormulaTerm, _ variable: String, _ depth: Int) -> String {
        if depth > 64 { return "…" }
        switch node {
        case .literal(let value): return value.description
        case .variable: return variable
        case .input(let index): return "c\(index + 1)"
        case .constant(let name): return name
        case .negate(let operand): return "-(" + write(operand, variable, depth + 1) + ")"
        case .call(let name, let operand): return name + "(" + write(operand, variable, depth + 1) + ")"
        case .binary(let operation, let left, let right): return "(" + write(left, variable, depth + 1) + " " + String(operation) + " " + write(right, variable, depth + 1) + ")"
        }
    }
}
