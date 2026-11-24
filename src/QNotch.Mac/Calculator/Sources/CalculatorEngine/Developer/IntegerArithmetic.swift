import Foundation

/// Radix literals, word profiles and bitwise operators (C# IntegerArithmetic).
final class IntegerArithmetic {
    static let convention = "Exact integers; finite words wrap modulo 2^width; matching word width/sign required; signed >> sign-extends, >>> zero-fills; shift counts are not masked; ^ is power, xor is exclusive-or; division keeps an exact fraction when needed"
    static func isFunction(_ name: String) -> Bool { ["hex", "bin", "oct", "dec", "uint", "sint", "bitand", "bitor", "bitxor", "bitnot", "shl", "shr", "ushr"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        let arity = ["hex", "bin", "oct", "dec", "bitnot"].contains(name.netLower) ? 1 : 2
        if count != arity { throw CalcError.format("\(name) expects \(arity) argument(s)") }
    }
    private let budget: ExecutionBudget
    private let token: CancellationToken
    init(_ budget: ExecutionBudget, _ token: CancellationToken) { self.budget = budget; self.token = token }
    private func step() throws { try budget.step(token) }
    private func make(_ value: BigInt, _ radix: Int = 10, _ width: Int? = nil, _ signed: Bool = false) throws -> SheetValue {
        // Charge bounded rendering work to the same budget as all nested calls.
        var i = 0; let limit = max(value.magnitude.bitLength, width ?? 0)
        while i <= limit { try step(); i += 64 }
        return .integer(try IntegerValue(value, radix, width, signed))
    }
    static func isExactInteger(_ value: SheetValue) -> Bool {
        switch value {
        case .integer: return true
        case .number(let n): return n.unit == nil && !n.isPercentage && !n.isApproximate && n.isRational && n.exact.constant.denominator.isOne
        default: return false
        }
    }
    static func require(_ value: SheetValue) throws -> BigInt {
        guard isExactInteger(value) else { throw CalcError.arithmetic("Expected an exact dimensionless integer (no percentage)") }
        if case .integer(let integer) = value { return integer.value }
        return try value.scalar.numerator
    }

    func literal(_ text: String) throws -> SheetValue {
        let u = text.units
        let radix: Int
        switch NetChar.lower(u[1]) {
        case UInt16(ascii: "x"): radix = 16
        case UInt16(ascii: "b"): radix = 2
        case UInt16(ascii: "o"): radix = 8
        default: throw CalcError.format("Invalid integer prefix")
        }
        var value = BigInt.zero; var digitSeen = false; var underscore = false
        for c in u[2...] {
            try step()
            if c == UInt16(ascii: "_") {
                if !digitSeen || underscore { throw CalcError.format("Misplaced integer separator") }
                underscore = true; continue
            }
            let digit = c >= 48 && c <= 57 ? Int(c) - 48 : c >= 97 && c <= 102 ? Int(c) - 97 + 10 : c >= 65 && c <= 70 ? Int(c) - 65 + 10 : -1
            if digit < 0 || digit >= radix { throw CalcError.format("Invalid integer digit") }
            value = value * BigInt(radix) + BigInt(digit); digitSeen = true; underscore = false
            if value.bitLength > IntegerValue.maximumBits { throw CalcError.arithmetic("Integer precision limit exceeded") }
        }
        if !digitSeen || underscore { throw CalcError.format("Invalid integer literal") }
        return try make(value, radix)
    }
    func convert(_ value: SheetValue, _ radix: Int?, _ width: Int?, _ signed: Bool) throws -> SheetValue {
        try step()
        var source: IntegerValue?; if case .integer(let integer) = value { source = integer }
        return try make(try IntegerArithmetic.require(value), radix ?? source?.radix ?? 10, width ?? source?.width, width == nil ? source?.signed ?? false : signed)
    }
    /// The word profile two operands share: matching widths/signs are required; a bare integer adopts the other's.
    private static func profile(_ left: SheetValue, _ right: SheetValue) throws -> IntegerValue? {
        var a: IntegerValue?, b: IntegerValue?
        if case .integer(let x) = left { a = x }
        if case .integer(let y) = right { b = y }
        if let a, let b, a.width != nil, b.width != nil, a.width != b.width || a.signed != b.signed { throw CalcError.arithmetic("Cast mixed integer widths/signs explicitly") }
        return a?.width != nil ? a : b?.width != nil ? b : a ?? b
    }
    /// Integer handling of a unary operator, or nil when it does not apply.
    func tryUnary(_ operation: String, _ value: SheetValue) throws -> SheetValue? {
        if operation != "~" && (value.kind != .integer || (operation != "+" && operation != "-")) { return nil }
        try step(); let n = try IntegerArithmetic.require(value)
        var p: IntegerValue?; if case .integer(let integer) = value { p = integer }
        return try make(operation == "~" ? ~n : operation == "-" ? -n : n, p?.radix ?? 10, p?.width, p?.signed ?? false)
    }
    /// Integer handling of a binary operator, or nil when it does not apply.
    func tryBinary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue? {
        let bitwise = ["&", "|", "xor", "<<", ">>", ">>>"].contains(operation)
        if !bitwise && (left.kind != .integer && right.kind != .integer || !["+", "-", "*", "/", "^"].contains(operation)) { return nil }
        if !bitwise && (!IntegerArithmetic.isExactInteger(left) || !IntegerArithmetic.isExactInteger(right)) { return nil }
        try step(); var a = try IntegerArithmetic.require(left); var b = try IntegerArithmetic.require(right); var n: BigInt
        let shifting = operation == "<<" || operation == ">>" || operation == ">>>"
        var leftInteger: IntegerValue?; if case .integer(let integer) = left { leftInteger = integer }
        let p = shifting || operation == "^" ? leftInteger : try IntegerArithmetic.profile(left, right)
        // A bare integer adopts the word profile, including its signed interpretation.
        func word(_ v: BigInt) -> BigInt {
            guard let p, let w = p.width else { return v }
            let masked = v & ((BigInt.one << w) - .one)
            return p.signed && masked >= BigInt.one << (w - 1) ? masked - (BigInt.one << w) : masked
        }
        a = word(a); if !shifting && operation != "^" { b = word(b) }
        if shifting {
            if b < .zero || b > BigInt(IntegerValue.maximumBits) { throw CalcError.arithmetic("Shift count must be 0–4096") }
            if operation == ">>>" && a.sign < 0 && p?.width == nil { throw CalcError.arithmetic("Logical right shift of a negative integer requires a word width") }
            var input = a
            if operation == ">>>", let w = p?.width { input = a & ((BigInt.one << w) - .one) }
            n = operation == "<<" ? input << b.intValue! : input >> b.intValue!
        } else {
            switch operation {
            case "&": n = a & b
            case "|": n = a | b
            case "xor": n = a ^ b
            case "+": n = a + b
            case "-": n = a - b
            case "*": n = a * b
            case "/":
                if b.isZero { throw CalcError.arithmetic(CalcError.divideByZeroMessage) }
                let (quotient, remainder) = a.quotientAndRemainder(dividingBy: b); n = quotient
                if !remainder.isZero { return SheetValue(try Rational(a, b)) }
            case "^":
                if b < .zero { return nil }
                if b > BigInt(1024) { throw CalcError.arithmetic("Integer power limit exceeded") }
                n = .one
                for _ in 0..<b.intValue! {
                    try step(); n = word(n * a)
                    if n.magnitude.bitLength > IntegerValue.maximumBits { throw CalcError.arithmetic("Integer precision limit exceeded") }
                }
            default: return nil
            }
        }
        return try make(n, leftInteger?.radix ?? p?.radix ?? 10, p?.width, p?.signed ?? false)
    }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue {
        try IntegerArithmetic.validateArity(name, args.count); let key = name.netLower
        if ["hex", "bin", "oct", "dec"].contains(key) { return try convert(args[0], key == "hex" ? 16 : key == "bin" ? 2 : key == "oct" ? 8 : 10, nil, false) }
        if key == "uint" || key == "sint" {
            let width = try IntegerArithmetic.require(args[1])
            if width < .one || width > BigInt(IntegerValue.maximumBits) { throw CalcError.arithmetic("Integer width must be 1–4096 bits") }
            return try convert(args[0], 10, width.intValue!, key == "sint")
        }
        // Bitwise operators always apply to integers, so these never fall through.
        if key == "bitnot" { return try tryUnary("~", args[0])! }
        let operation = key == "bitand" ? "&" : key == "bitor" ? "|" : key == "bitxor" ? "xor" : key == "shl" ? "<<" : key == "shr" ? ">>" : ">>>"
        return try tryBinary(operation, args[0], args[1])!
    }
}
