import Foundation

/// Bounded one-variable real formula AST shared by equations, calculus and plotting (C# FormulaTerm records).
/// Sheet names are captured inputs. C# records compare by value; so does this enum.
indirect enum FormulaTerm: Hashable {
    case literal(Rational)
    case variable
    case input(Int)
    case constant(String)
    case negate(FormulaTerm)
    /// One of + - * / ^.
    case binary(Character, FormulaTerm, FormulaTerm)
    case call(String, FormulaTerm)
}

enum FormulaFunctions {
    static let convention = "Double-precision evaluation; angles in radians; ln is natural, log is base 10"
    static let maxNodes = 256
    static func isSheetFunction(_ name: String) -> Bool {
        ["sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "exp", "ln", "log"].contains(name.netLower)
    }
    static func isFormulaFunction(_ name: String) -> Bool { isSheetFunction(name) || ["sqrt", "abs"].contains(name.netLower) }
    static func isConstant(_ name: String) -> Bool { ["pi", "π", "e", "tau", "τ", "phi", "φ"].contains(name.netLower) }
    /// Math.E, Math.Tau, (1 + Math.Sqrt(5)) / 2 and Math.PI.
    static func constant(_ name: String) -> Double {
        switch name.netLower {
        case "e": return M_E
        case "tau", "τ": return 2 * Double.pi
        case "phi", "φ": return (1 + 5.0.squareRoot()) / 2
        default: return Double.pi
        }
    }
    /// .NET's Math functions on macOS call the platform libm, as Foundation does.
    static func apply(_ name: String, _ x: Double) throws -> Double {
        switch name {
        case "sin": return Foundation.sin(x)
        case "cos": return Foundation.cos(x)
        case "tan": return Foundation.tan(x)
        case "asin": return Foundation.asin(x)
        case "acos": return Foundation.acos(x)
        case "atan": return Foundation.atan(x)
        case "sinh": return Foundation.sinh(x)
        case "cosh": return Foundation.cosh(x)
        case "tanh": return Foundation.tanh(x)
        case "exp": return Foundation.exp(x)
        case "ln": return x > 0 ? Foundation.log(x) : .nan
        case "log": return x > 0 ? Foundation.log10(x) : .nan
        case "sqrt": return x >= 0 ? x.squareRoot() : .nan
        case "abs": return Swift.abs(x)
        default: throw CalcError.format("Unknown formula function: \(name)")
        }
    }
    static func count(_ term: FormulaTerm) throws -> Int {
        var stack = [term]; var count = 0
        while let node = stack.popLast() {
            count += 1
            if count > 65536 { throw CalcError.arithmetic("Formula size limit exceeded") }
            switch node {
            case .negate(let operand): stack.append(operand)
            case .call(_, let operand): stack.append(operand)
            case .binary(_, let left, let right): stack.append(left); stack.append(right)
            default: break
            }
        }
        return count
    }
    static func dependsOnVariable(_ term: FormulaTerm) -> Bool {
        switch term {
        case .variable: return true
        case .negate(let operand): return dependsOnVariable(operand)
        case .call(_, let operand): return dependsOnVariable(operand)
        case .binary(_, let left, let right): return dependsOnVariable(left) || dependsOnVariable(right)
        default: return false
        }
    }
}

/// Sampling entry point for solvers and plotters: the value at x, or NaN/infinity when undefined. One budget step per sample.
final class Formula {
    let term: FormulaTerm
    let variable: String
    let inputs: [Double]
    init(_ term: FormulaTerm, _ variable: String, _ inputs: [Double]) { self.term = term; self.variable = variable; self.inputs = inputs }
    func with(_ replacement: FormulaTerm) -> Formula { Formula(replacement, variable, inputs) }
    func sample(_ x: Double, _ budget: ExecutionBudget, _ token: CancellationToken) throws -> Double {
        try budget.step(token); return try evaluate(term, x)
    }
    private func evaluate(_ node: FormulaTerm, _ x: Double) throws -> Double {
        switch node {
        case .literal(let value): return FormulaNumbers.toDouble(value)
        case .variable: return x
        case .input(let index): return inputs[index]
        case .constant(let name): return FormulaFunctions.constant(name)
        case .negate(let operand): return -(try evaluate(operand, x))
        case .call(let name, let operand): return try FormulaFunctions.apply(name, try evaluate(operand, x))
        case .binary(let operation, let left, let right): return try Formula.binary(operation, try evaluate(left, x), try evaluate(right, x))
        }
    }
    private static func binary(_ operation: Character, _ left: Double, _ right: Double) throws -> Double {
        switch operation {
        case "+": return left + right
        case "-": return left - right
        case "*": return left * right
        case "/": return right == 0 ? .nan : left / right
        case "^": return Foundation.pow(left, right)
        default: throw CalcError.format("Unknown formula operator")
        }
    }
}

/// The captured sheet inputs of one or more formulas parsed together (C# shares a List and an OrdinalIgnoreCase Dictionary).
struct FormulaInputs {
    var expressions: [Expression] = []
    var indices = NetDictionary<String, Int>.ignoringCase()
}

/// Scalar algebra over tokens: + - * / ^, implicit multiplication (2x, 2(x+1)), unary minus, the listed functions, pi and e.
final class FormulaParser {
    private let tokens: [Token]
    private let variable: String
    private var inputs: FormulaInputs
    private let knownNames: NetHashSet<String>?
    private let token: CancellationToken
    private var position = 0, depth = 0, nodes = 0

    private init(_ tokens: [Token], _ variable: String, _ inputs: FormulaInputs, _ knownNames: NetHashSet<String>?, _ token: CancellationToken) {
        self.tokens = tokens; self.variable = variable; self.inputs = inputs; self.knownNames = knownNames; self.token = token
    }
    private var current: Token { position < tokens.count ? tokens[position] : Token(.end, "") }
    private func take(_ text: String) -> Bool { if !current.text.equalsIgnoreCase(text) { return false }; position += 1; return true }
    private func made(_ term: FormulaTerm) throws -> FormulaTerm {
        nodes += 1
        if nodes > FormulaFunctions.maxNodes { throw CalcError.arithmetic("Formula size limit exceeded") }
        return term
    }
    static func parse(_ tokens: [Token], _ variable: String, _ inputs: inout FormulaInputs, _ knownNames: NetHashSet<String>?, _ token: CancellationToken) throws -> FormulaTerm {
        let parser = FormulaParser(tokens, variable, inputs, knownNames, token)
        let term = try parser.parse()
        inputs = parser.inputs
        return term
    }
    private func parse() throws -> FormulaTerm {
        if tokens.isEmpty { throw CalcError.format("Expected a formula") }
        let term = try sum()
        if position != tokens.count { throw CalcError.format("Unexpected formula text; only scalar algebra is supported") }
        return term
    }
    private func sum() throws -> FormulaTerm {
        var value = try product()
        while current.text == "+" || current.text == "-" {
            let op = current.text.first!; position += 1
            value = try made(.binary(op, value, try product()))
        }
        return value
    }
    private func product() throws -> FormulaTerm {
        var value = try unary()
        while true {
            if current.text == "*" || current.text == "/" || current.text == "·" {
                let op: Character = current.text == "·" ? "*" : current.text.first!; position += 1
                value = try made(.binary(op, value, try unary()))
            } else if current.kind == .name || current.text == "(" {
                try rejectExponentNotation(); value = try made(.binary("*", value, try unary()))
            } else { return value }
        }
    }
    // 1e-10 tokenizes as 1, e, -, 10; reading it as 1·e - 10 would be a silent wrong number. A sheet variable named e still wins.
    private func rejectExponentNotation() throws {
        let text = current.text.units
        guard current.kind == .name && current.joinedToPrevious && position > 0 && tokens[position - 1].kind == .number && knownNameLength() == 0 else { return }
        let isE = current.text == "e" || current.text == "E"
        let isExponent = text.count > 1 && (text[0] == 0x65 || text[0] == 0x45) && text.dropFirst().allSatisfy(NetChar.isAsciiDigit)
        if isE || isExponent { throw CalcError.format("Scientific notation is not supported in formulas; write 1*10^-10, or 2*e for Euler's number") }
    }
    private func unary() throws -> FormulaTerm {
        try token.throwIfCancellationRequested()
        depth += 1
        defer { depth -= 1 }
        if depth > 48 { throw CalcError.arithmetic("Formula depth limit exceeded") }
        if take("+") { return try unary() }
        if take("-") { return try made(.negate(try unary())) }
        var value = try atom()
        if take("^") { value = try made(.binary("^", value, try unary())) }
        return value
    }
    private func atom() throws -> FormulaTerm {
        if take("(") {
            let value = try sum()
            if !take(")") { throw CalcError.format("Expected formula closing parenthesis") }
            return value
        }
        if current.kind == .number { let n = try Rational.parse(current.text); position += 1; return try made(.literal(n)) }
        if current.kind != .name { throw CalcError.format("Expected a formula term") }
        var name = current.text
        let next = position + 1 < tokens.count ? tokens[position + 1].text : ""
        let known = knownNameLength()
        if known <= 1 && !name.equalsIgnoreCase(variable) && next == "(" && FormulaFunctions.isFormulaFunction(name) {
            position += 2; let argument = try sum()
            if !take(")") { throw CalcError.format(name + " expects one argument") }
            return try made(.call(name.netLower, argument))
        }
        if known > 1 { name = tokens[position..<(position + known)].map(\.text).joined(separator: " "); position += known }
        else { position += 1 }
        if name.equalsIgnoreCase(variable) { return try made(.variable) }
        if known == 0 && FormulaFunctions.isConstant(name) { return try made(.constant(name.netLower)) }
        if known == 0 && name == "i" { throw CalcError.format("Formulas are real-valued; the imaginary unit i is not supported here") }
        if known == 0 && ConstantCatalog.isPhysical(name) {
            // Case-sensitive aliases must not share a case-insensitive sheet input.
            let key = "\0" + name
            var slot = inputs.indices[key]
            if slot == nil { slot = inputs.expressions.count; inputs.indices.set(key, slot!); inputs.expressions.append(ConstantExpression(name, magnitude: true)) }
            return try made(.input(slot!))
        }
        var index = inputs.indices[name]
        if index == nil { index = inputs.expressions.count; inputs.indices.set(name, index!); inputs.expressions.append(NameExpression(name)) }
        return try made(.input(index!))
    }
    private func knownNameLength() -> Int {
        guard let knownNames, !knownNames.isEmpty else { return 0 }
        var words: [String] = []; var best = 0; var length = 0
        var end = position
        while end < tokens.count && tokens[end].kind == .name {
            length += tokens[end].text.netLength + (end == position ? 0 : 1)
            if length > 128 { break }
            words.append(tokens[end].text)
            if knownNames.contains(words.joined(separator: " ")) { best = words.count }
            end += 1
        }
        return best
    }
}
