// Stub for the math area: matrices, statistics, complex numbers, primes, equations, calculus and formulas.

class FormulaTerm {}
final class EquationExpression: Expression {
    let variable: String, left: FormulaTerm, right: FormulaTerm, inputs: [Expression], hasDomain: Bool
    init(_ variable: String, _ left: FormulaTerm, _ right: FormulaTerm, _ inputs: [Expression], _ hasDomain: Bool) { self.variable = variable; self.left = left; self.right = right; self.inputs = inputs; self.hasDomain = hasDomain }
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
final class EquationValue: IdentityHashable {
    var isApproximate: Bool { false }
    var display: String { get throws { throw notPorted("solve") } }
    var copyText: String { get throws { try display } }
}
final class ComplexValue: IdentityHashable {
    var isApproximate: Bool { false }
    var display: String { get throws { throw notPorted("complex numbers") } }
    var copyText: String { get throws { try display } }
}
final class PrimeValue: IdentityHashable {
    var display: String { get throws { throw notPorted("primes") } }
    var copyText: String { get throws { try display } }
}
enum FormulaFunctions {
    static let convention = "Double-precision evaluation; angles in radians; ln is natural, log is base 10"
    static func isSheetFunction(_ name: String) -> Bool { ["sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "exp", "ln", "log"].contains(name.netLower) }
    static func isConstant(_ name: String) -> Bool { ["pi", "π", "e", "tau", "τ", "phi", "φ"].contains(name.netLower) }
}
enum EquationSyntax {
    static func prefix(_ text: String) -> Bool {
        let u = text.units
        return u.count > 6 && text.startsWithIgnoreCase("solve") && NetChar.isWhiteSpace(u[5]) && u.contains(0x3D) && !text.netSubstring(6).netTrimStart.hasPrefix("=")
    }
    static func function(_ name: String) -> Bool { ["solutionroot", "solutioncount"].contains(name.netLower) }
    static func arity(_ name: String) -> Int { name.equalsIgnoreCase("solutionRoot") ? 2 : 1 }
    static func parse(_ text: String, _ names: NetHashSet<String>, _ token: CancellationToken) throws -> Expression { throw notPorted("solve") }
    static func sides(_ text: String) throws -> [String] { throw notPorted("solve") }
}
enum CalculusSyntax {
    static func isFunction(_ name: String) -> Bool { ["integral", "derivative"].contains(name.netLower) }
    static func arity(_ name: String) -> Int { name.equalsIgnoreCase("integral") ? 3 : 2 }
}
extension ExpressionParser {
    func parseCalculus(_ name: String) throws -> Expression { throw notPorted("integrals and derivatives") }
}
final class FormulaArithmetic {
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) {}
    func solve(_ expression: EquationExpression, _ inputs: [SheetValue]) throws -> (value: SheetValue, assumption: String) { throw notPorted("solve") }
    func integrate(_ expression: IntegralExpression, _ inputs: [SheetValue]) throws -> (value: SheetValue, assumption: String) { throw notPorted("integrals") }
    func differentiate(_ expression: DerivativeExpression, _ inputs: [SheetValue]) throws -> (value: SheetValue, assumption: String) { throw notPorted("derivatives") }
    func solutionFunction(_ name: String, _ args: [SheetValue]) throws -> SheetValue { throw notPorted("solve") }
    func sheetFunction(_ name: String, _ args: [SheetValue]) throws -> SheetValue { throw notPorted("trigonometry") }
}
final class MatrixArithmetic {
    static let convention = "Real linear algebra; row-major matrices, column-vector A*v / row-vector v*A; exact represented arithmetic; no numerical tolerance or approximate singularity test"
    static func isFunction(_ name: String) -> Bool { ["det", "determinant", "inverse", "inv", "transpose", "trace", "dot", "cross", "norm"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        let expected = ["dot", "cross"].contains(name.netLower) ? 2 : 1
        if count != expected { throw CalcError.format("\(name) expects \(expected) argument(s)") }
    }
    static func isCollection(_ value: SheetValue) -> Bool { value.kind == .list || value.kind == .matrix }
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) {}
    func unary(_ operation: String, _ value: SheetValue) throws -> SheetValue { throw notPorted("list and matrix arithmetic") }
    func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue { throw notPorted("list and matrix arithmetic") }
    func round(_ kind: RoundingKind, _ value: SheetValue, _ precision: SheetValue) throws -> SheetValue { throw notPorted("list and matrix rounding") }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue { throw notPorted("matrix functions") }
}
final class ComplexArithmetic {
    static let convention = "Exact parts where representable; principal values, arg in radians over (-pi, pi]; plain numbers only: no units, money, lists or matrices"
    static let refusal = "Complex values combine only with plain numbers, not units, percentages, money, lists or matrices"
    static func isFunction(_ name: String) -> Bool { ["re", "im", "conj", "arg"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws { if count != 1 { throw CalcError.format("\(name) expects 1 argument(s)") } }
    static func literal(_ coefficient: Rational) throws -> SheetValue { throw notPorted("complex numbers") }
    init(_ math: ExactArithmetic, _ quantities: QuantityArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) {}
    func applies(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> Bool { left.kind == .complex || right.kind == .complex }
    func applies(_ name: String, _ args: [SheetValue]) throws -> Bool { ComplexArithmetic.isFunction(name) || args.count == 1 && args[0].kind == .complex && ["abs", "sqrt"].contains(name.netLower) }
    func scale(_ value: SheetValue, _ factor: Rational) throws -> SheetValue { throw notPorted("complex numbers") }
    func unary(_ operation: String, _ value: SheetValue) throws -> SheetValue { throw notPorted("complex numbers") }
    func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue { throw notPorted("complex numbers") }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue { throw notPorted("complex numbers") }
    func round(_ kind: RoundingKind, _ value: SheetValue, _ precision: NumericValue) throws -> SheetValue { throw notPorted("complex numbers") }
}
final class PrimeArithmetic {
    static let notNumeric = "Primality and factorization results are not numbers"
    static func isFunction(_ name: String) -> Bool { ["isprime", "factor", "nextprime", "prevprime"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws { if count != 1 { throw CalcError.format("\(name) expects 1 argument(s)") } }
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) {}
    func function(_ name: String, _ args: [SheetValue]) throws -> (value: SheetValue, evidence: String) { throw notPorted("primes") }
}
final class StatisticsArithmetic {
    static func isFunction(_ name: String) -> Bool {
        ["sum", "mean", "average", "avg", "median", "min", "max", "count", "stdev", "stddev", "stdevp", "variance", "variancep", "percentile"].contains(name.netLower)
    }
    static func validateArity(_ name: String, _ count: Int) throws {
        if name.equalsIgnoreCase("percentile") { if count != 2 { throw CalcError.format("percentile expects 2 arguments") } }
        else if count < 1 || count > 16 { throw CalcError.format("\(name) expects 1–16 arguments or a list") }
    }
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic) {}
    func function(_ name: String, _ args: [SheetValue]) throws -> (value: SheetValue, assumption: String) { throw notPorted("statistics") }
}
