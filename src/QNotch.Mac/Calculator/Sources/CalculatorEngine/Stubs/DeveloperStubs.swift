// Stub for the developer area: colours, permissions, aspect ratios, Unicode, integers, networks, text codecs,
// usage rates, UUIDs and dice.

enum NetworkForm { case address, subnet, prefix, membership }
final class IntegerValue: IdentityHashable {
    static let maximumBits = 4096
    let value: BigInt
    init(_ value: BigInt) { self.value = value }
    var display: String { get throws { throw notPorted("integers") } }
    var copyText: String { get throws { try display } }
}
final class NetworkValue: IdentityHashable {
    let form: NetworkForm
    init(_ form: NetworkForm) { self.form = form }
    var display: String { get throws { throw notPorted("networks") } }
    var copyText: String { get throws { try display } }
}
final class ColourValue: IdentityHashable {
    var display: String { get throws { throw notPorted("colours") } }
    var copyText: String { get throws { try display } }
}
final class PermissionValue: IdentityHashable {
    var display: String { get throws { throw notPorted("permissions") } }
    var copyText: String { get throws { try display } }
}
final class AspectValue: IdentityHashable {
    var display: String { get throws { throw notPorted("aspect ratios") } }
    var copyText: String { get throws { try display } }
}
final class UnicodeValue: IdentityHashable {
    var display: String { get throws { throw notPorted("Unicode") } }
    var copyText: String { get throws { try display } }
}
final class UsageCountValue: IdentityHashable {
    let quantity = NumericValue()
    var display: String { get throws { throw notPorted("usage rates") } }
    var copyText: String { get throws { try display } }
}
final class UsagePriceValue: IdentityHashable {
    let amount: MoneyValue, perCount: Rational, kind: UsageKind?
    init(_ amount: MoneyValue, _ perCount: Rational, _ kind: UsageKind?) throws { self.amount = amount; self.perCount = perCount; self.kind = kind }
    var display: String { get throws { throw notPorted("usage prices") } }
    var copyText: String { get throws { try display } }
}
final class UptimeBudgetValue: IdentityHashable {
    var details: String { get throws { throw notPorted("uptime budgets") } }
    var display: String { get throws { throw notPorted("uptime budgets") } }
    var copyText: String { get throws { try display } }
}
final class DeveloperArithmetic {
    static let convention = "Exact represented helper values; conversions retain stored data; permission and Unicode queries do not inspect or change OS state"
    static func isFunction(_ name: String) -> Bool {
        ["color", "colour", "rgb", "rgba", "hsl", "hsla", "colourhex", "chmod", "modebits", "modeoctal", "aspect", "asratio", "unicode", "codepoint", "chr"].contains(name.netLower)
    }
    static func isTextFunction(_ name: String) -> Bool { ["color", "colour", "chmod", "unicode"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        let valid: Bool
        switch name.netLower { case "rgb", "hsl": valid = [1, 3, 4].contains(count); case "rgba", "hsla": valid = count == 4; case "aspect": valid = count == 2; default: valid = count == 1 }
        if !valid { throw CalcError.format("\(name) has an invalid argument count") }
    }
    init(_ budget: ExecutionBudget, _ token: CancellationToken) {}
    func colourLiteral(_ text: String) throws -> SheetValue { throw notPorted("colours") }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue { throw notPorted("developer helpers") }
}
final class TextArithmetic {
    static let convention = "Exact UTF-8 text; no BOM, case folding or Unicode normalization; codecs transform text only"
    static func isFunction(_ name: String) -> Bool { ["text", "base64", "decodebase64", "urlencode", "urldecode", "md5", "sha1", "sha256"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws { if count != 1 { throw CalcError.format("\(name) expects 1 argument") } }
    init(_ budget: ExecutionBudget, _ token: CancellationToken) {}
    func literal(_ value: String) throws -> SheetValue { .text(try TextValue(value)) }
    func function(_ name: String, _ args: [SheetValue]) throws -> (value: SheetValue, evidence: TextTransformEvidence) { throw notPorted("text codecs") }
}
final class NetworkArithmetic {
    static let convention = "Numeric addresses only; CIDR host bits are normalized; counts describe address space, not reachability. IPv4 /31 uses the point-to-point host model; IPv6 host assignment is not inferred"
    static func isFunction(_ name: String) -> Bool {
        ["subnet", "contains", "netmask", "cidr", "network", "firstip", "lastip", "ipcount", "hostcount", "firsthost", "lasthost", "broadcast", "subnetmask"].contains(name.netLower)
    }
    static func validateArity(_ name: String, _ count: Int) throws {
        let expected = ["subnet", "contains", "netmask"].contains(name.netLower) ? 2 : 1
        if count != expected { throw CalcError.format("\(name) expects \(expected) argument(s)") }
    }
    init(_ budget: ExecutionBudget, _ token: CancellationToken) {}
    func literal(_ text: String) throws -> SheetValue { throw notPorted("networks") }
    func prefixMask(_ prefix: Int, _ family: Int) throws -> SheetValue { throw notPorted("networks") }
    func contains(_ candidate: SheetValue, _ target: SheetValue) throws -> SheetValue { throw notPorted("networks") }
    func attach(_ address: SheetValue, _ prefix: SheetValue) throws -> SheetValue { throw notPorted("networks") }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue { throw notPorted("networks") }
}
final class IntegerArithmetic {
    static let convention = "Exact integers; finite words wrap modulo 2^width; matching word width/sign required; signed >> sign-extends, >>> zero-fills; shift counts are not masked; ^ is power, xor is exclusive-or; division keeps an exact fraction when needed"
    static func isFunction(_ name: String) -> Bool { ["hex", "bin", "oct", "dec", "uint", "sint", "bitand", "bitor", "bitxor", "bitnot", "shl", "shr", "ushr"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        let arity = ["hex", "bin", "oct", "dec", "bitnot"].contains(name.netLower) ? 1 : 2
        if count != arity { throw CalcError.format("\(name) expects \(arity) argument(s)") }
    }
    init(_ budget: ExecutionBudget, _ token: CancellationToken) {}
    func literal(_ text: String) throws -> SheetValue { throw notPorted("integer literals") }
    func convert(_ value: SheetValue, _ radix: Int?, _ width: Int?, _ signed: Bool) throws -> SheetValue { throw notPorted("integer conversion") }
    /// Integer handling of a unary operator, or nil when it does not apply.
    func tryUnary(_ operation: String, _ value: SheetValue) throws -> SheetValue? {
        if value.kind == .integer { throw notPorted("integers") }
        if operation == "~" { throw notPorted("bitwise operators") }
        return nil
    }
    /// Integer handling of a binary operator, or nil when it does not apply.
    func tryBinary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue? {
        if left.kind == .integer || right.kind == .integer || ["&", "|", "xor", "<<", ">>", ">>>"].contains(operation) { throw notPorted("integers") }
        return nil
    }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue { throw notPorted("integer functions") }
}
final class RateArithmetic {
    static let data = Dimension(0, 0, 0, 0, 0, 0, 0, 1)
    static let convention = "Exact represented rates; SI/binary and bit/byte scales retained; ideal constant payload transfer or flat prorated supplied prices; no network, billing provider or availability measurement"
    static func isFunction(_ name: String) -> Bool {
        ["transfer", "throughput", "uptime", "downtime", "tokens", "requests", "items", "tokenprice", "requestprice", "itemprice", "usageprice", "usagecost", "usagefor"].contains(name.netLower)
    }
    static func validateArity(_ name: String, _ count: Int) throws {
        let valid: Bool
        switch name.netLower { case "tokens", "requests", "items": valid = count == 1; case "uptime": valid = count == 1 || count == 2; default: valid = count == 2 }
        if !valid { throw CalcError.format("\(name) has an invalid argument count") }
    }
    static func evidence(_ value: SheetValue) throws -> String { throw notPorted("usage rates") }
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic) {}
    func nominal(_ value: UptimeBudgetValue) throws -> SheetValue { throw notPorted("uptime budgets") }
    func convertCount(_ value: UsageCountValue, _ kind: UsageKind, _ unit: UnitExpression?) throws -> SheetValue { throw notPorted("usage rates") }
    func count(_ value: SheetValue, _ kind: UsageKind) throws -> SheetValue { throw notPorted("usage counts") }
    func price(_ value: SheetValue, _ perCount: Rational, _ kind: UsageKind?) throws -> SheetValue { throw notPorted("usage prices") }
    func forDuration(_ rate: SheetValue, _ duration: SheetValue) throws -> SheetValue { throw notPorted("rate totals") }
    func at(_ amount: SheetValue, _ rate: SheetValue) throws -> SheetValue { throw notPorted("rates") }
    func attach(_ value: UsageCountValue, _ unit: UnitExpression, _ conversion: Bool) throws -> SheetValue { throw notPorted("usage rates") }
    func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue { throw notPorted("usage rates") }
    func unary(_ operation: String, _ value: SheetValue) throws -> SheetValue { throw notPorted("usage rates") }
    func throughput(_ data: SheetValue, _ time: SheetValue) throws -> SheetValue { throw notPorted("throughput") }
    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue { throw notPorted("rate functions") }
    func aggregate(_ values: [SheetValue], _ average: Bool) throws -> SheetValue { throw notPorted("usage rates") }
    func round(_ kind: RoundingKind, _ value: SheetValue, _ precision: SheetValue) throws -> SheetValue { throw notPorted("usage rates") }
}
extension ExpressionParser {
    func tryRateForSentence() throws -> Expression? { nil }
}
struct UuidRequest: Hashable { let line: Int, site: String }
struct DiceRoll { let formula: String; let faces: [Int] }
final class StableUuidContext {
    static let maxBindings = 4096
    func resolve(_ line: Int, _ path: String, _ site: Int, _ reads: ContextReads) throws -> String { throw notPorted("UUIDs") }
    func dice(_ line: Int) -> DiceRoll? { nil }
    func key(_ line: Int) -> String? { nil }
    func diceKey(_ line: Int) -> String? { nil }
}
final class DiceFormula {
    var notation: String { "" }
    func fits(_ faces: [Int]) -> Bool { false }
}
final class DiceExpression: Expression { let formula: DiceFormula; init(_ formula: DiceFormula) { self.formula = formula } }
enum DiceSyntax {
    static func tryParse(_ text: String, _ names: NetHashSet<String>) throws -> DiceFormula? { nil }
    static func preview(_ formula: DiceFormula) throws -> (preview: String, steps: [CalculationStep]) { throw notPorted("dice") }
    static func total(_ formula: DiceFormula, _ faces: [Int]) throws -> (total: Int64, steps: [CalculationStep]) { throw notPorted("dice") }
}
