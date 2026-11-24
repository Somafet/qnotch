import Foundation
import CryptoKit

// C# System.Guid is Foundation's UUID here: both keep the 16 bytes in textual (big-endian) order.
extension UUID {
    /// Guid.Empty.
    static let empty = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    /// Guid.ToString("D"): lowercase, hyphenated.
    var dashed: String { uuidString.lowercased() }
    /// Guid.ToString("N"): lowercase, 32 digits.
    var compact: String { dashed.netReplace("-", "") }
    /// Guid.Parse for the "D" form ("N", braces and parentheses are not needed by the engine).
    static func parse(_ text: String) -> UUID? { UUID(uuidString: text) }
}

struct UuidBinding: Hashable { let statement: UUID; let site: String; let value: UUID }
struct UuidRequest: Hashable { let line: Int; let site: String }
/// C# `StableUuidContext.Key(line)`: the statement and a digest of its bindings.
struct UuidLineKey: Hashable { let statement: UUID; let values: String? }

/// Immutable document-owned UUID bindings (C# StableUuidContext). Core never obtains entropy or mutates generated state.
final class StableUuidContext {
    static let maxBindings = 1024
    static let maxSiteCharacters = 64000
    static let maxDiceBindings = 1024
    static let maxDiceFaces = 100_000
    private let statements: [UUID]
    private var dice: [UUID: DiceBinding] = [:]
    private var diceKeys: [UUID: String] = [:]
    private var bindings: [UUID: [String: UUID]] = [:]
    private var keys: [UUID: String] = [:]

    init(_ statementIds: [UUID], _ values: [UuidBinding], _ rolls: [DiceBinding]? = nil) throws {
        statements = Array(statementIds.prefix(SheetEvaluator.maxLines + 1))
        let ids = Set(statements)
        if statements.count < 1 || statements.count > SheetEvaluator.maxLines || ids.contains(.empty) || ids.count != statements.count {
            throw CalcError.argument("Invalid UUID statement identities")
        }
        var count = 0, characters = 0
        for binding in values {
            count += 1
            if count > StableUuidContext.maxBindings || !ids.contains(binding.statement) || !StableUuidContext.validSite(binding.site) || !StableUuidContext.isVersion4(binding.value) {
                throw CalcError.argument("Invalid or excessive UUID bindings")
            }
            characters += binding.site.netLength
            if characters > StableUuidContext.maxSiteCharacters { throw CalcError.argument("Invalid or excessive UUID bindings") }
            if bindings[binding.statement]?[binding.site] != nil { throw CalcError.argument("Duplicate UUID binding") }
            bindings[binding.statement, default: [:]][binding.site] = binding.value
        }
        var faces = 0
        for roll in rolls ?? [] {
            faces += roll.faces.count
            guard dice.count < StableUuidContext.maxDiceBindings, ids.contains(roll.statement), faces <= StableUuidContext.maxDiceFaces,
                  let formula = try DiceSyntax.tryParse(roll.formula), formula.notation == roll.formula, formula.fits(roll.faces), dice[roll.statement] == nil else {
                throw CalcError.argument("Invalid or excessive dice rolls")
            }
            dice[roll.statement] = roll
            diceKeys[roll.statement] = roll.formula + "=" + roll.faces.map(String.init).joined(separator: ",")
        }
        for (statement, row) in bindings {
            keys[statement] = sha256Hex(row.keys.sorted { String.ordinalCompare($0, $1) < 0 }.map { $0 + "=" + row[$0]!.dashed }.joined(separator: "\n"))
        }
    }
    static func isVersion4(_ value: UUID) -> Bool {
        let text = Array(value.compact.utf16)
        return text[12] == UInt16(ascii: "4") && "89ab".utf16.contains(text[16])
    }
    static func validSite(_ site: String?) -> Bool {
        guard let site else { return false }
        let u = site.units
        return u.count > 0 && u.count <= 8192 && !u.contains(0) && !u.contains(0x0A) && !u.contains(0x0D)
    }
    func statement(_ line: Int) throws -> UUID {
        guard line >= 0 && line < statements.count else { throw CalcError.argument("Specified argument was out of the range of valid values. (Parameter 'line')") }
        return statements[line]
    }
    var hasDice: Bool { !dice.isEmpty }
    func dice(_ line: Int) -> DiceBinding? { line >= 0 && line < statements.count ? dice[statements[line]] : nil }
    func diceKey(_ line: Int) -> String? { line >= 0 && line < statements.count ? diceKeys[statements[line]] : nil }
    /// Out of range gives C#'s `default` tuple: the empty statement with no values.
    func key(_ line: Int) -> UuidLineKey { line >= 0 && line < statements.count ? UuidLineKey(statement: statements[line], values: keys[statements[line]]) : UuidLineKey(statement: .empty, values: nil) }
    func resolve(_ line: Int, _ path: String, _ site: Int, _ reads: ContextReads) throws -> String {
        if line < 0 || line >= statements.count || site < 0 || path.netLength > 8190 { throw CalcError.arithmetic("UUID generation scope unavailable") }
        let key = path + "/" + String(site)
        if !StableUuidContext.validSite(key) { throw CalcError.arithmetic("UUID generation scope unavailable") }
        if let value = bindings[statements[line]]?[key] { return value.dashed }
        if reads.uuidRequests.count >= StableUuidContext.maxBindings { throw CalcError.arithmetic("UUID generation limit exceeded") }
        reads.uuidRequests.insert(UuidRequest(line: line, site: key))
        // Discovery may continue through the expression graph, but pending values/traces are masked before return.
        return "00000000-0000-4000-8000-000000000000"
    }
}

enum UuidSyntax {
    /// Formatting and annotations do not change a generated expression's identity.
    static func expressionIdentity(_ source: String) throws -> String? {
        do {
            let line = try SheetSyntax.scan(source)
            if line.error != nil || line.boundary || line.directive != nil || line.text.isEmpty { return nil }
            // Labels, spacing and case keep a roll; changing the dice clears it.
            if let dice = try DiceSyntax.tryParse(line.text) { return "dice:" + dice.notation }
            return try FunctionLibrary.canonical(FunctionDefinition(name: "_", parameters: [], body: line.text))
        } catch let error as CalcError where error.isFormatOrArithmetic { return nil }
    }
    /// Recognize actual generation, including transitive calls; comments/text/unused declarations do not activate it.
    static func requiresState(_ source: String, _ library: FunctionLibrary? = nil, token: CancellationToken = .none) throws -> Bool {
        let library = library ?? .empty
        if source.netUpper.netIndexOf("UUID") < 0 && !library.hasUuid { return false }
        if source.netLength > SheetEvaluator.maxCharacters { throw CalcError.argument("Sheet exceeds document limit") }
        let lines = SheetEvaluator.splitLines(source)
        if lines.count > SheetEvaluator.maxLines { return false }
        let scanned = try lines.map { try SheetSyntax.scan($0, token) }
        let update = try FunctionUpdate.prepare(source, scanned, library, [], token)
        let names = NetHashSet.ignoringCase(scanned.compactMap(\.assignment))
        for line in scanned {
            try token.throwIfCancellationRequested()
            if line.functionName != nil || line.directive != nil { continue }
            let parsed = try SheetSyntax.parse(line, names, token)
            if parsed.error == nil, let expression = parsed.expression, ExpressionEvaluation.walk(expression).contains(where: { node in
                node is UuidExpression || (node as? CallExpression).map { update.library.usesUuid($0.name) } == true
            }) { return true }
        }
        return false
    }
}
