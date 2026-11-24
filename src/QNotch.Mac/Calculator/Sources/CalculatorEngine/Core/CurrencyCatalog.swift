import Foundation

struct CurrencyDefinition: Hashable { let code: String, name: String, digits: Int, kind: String, aliases: [String] }

enum CurrencyCatalog {
    private struct Tables {
        var codes = NetDictionary<String, CurrencyDefinition>.ignoringCase()
        var aliases = NetDictionary<String, CurrencyDefinition>.ignoringCase()
        var symbols: [[UInt16]] = []
        var definitions: [CurrencyDefinition] = []
    }
    static let version = "2026-10-31"
    private static let tables: Tables = { do { return try load() } catch { fatalError("Invalid currency catalog: \(error)") } }()
    private static func load() throws -> Tables {
        let root = try JSONNode.parse(CalculatorEngine.resource("Currencies.json"))
        var t = Tables()
        for item in try root.property("currencies").arrayItems() {
            let code = try item.property("code").string(), name = try item.property("name").string()
            let digits = try item.property("digits").int(), kind = try item.property("kind").string()
            let names = try item.property("aliases").arrayItems().map { try $0.string() }
            if !validCode(code) || name.netLength < 1 || name.netLength > 256 || digits < 0 || digits > 8 || names.count > 16 ||
                names.contains(where: { $0.netLength < 1 || $0.netLength > 64 }) || t.definitions.count >= 512 { throw CalcError.invalidData("Invalid currency catalog") }
            let definition = CurrencyDefinition(code: code, name: name, digits: digits, kind: kind, aliases: names)
            guard t.codes.tryAdd(code, definition), t.aliases.tryAdd(code, definition) else { throw CalcError.argument("An item with the same key has already been added. Key: " + code) }
            for alias in names where !t.aliases.tryAdd(alias, definition) { throw CalcError.argument("An item with the same key has already been added. Key: " + alias) }
            t.definitions.append(definition)
        }
        let symbolKeys = t.aliases.keys.filter { $0.utf16.contains { NetChar.category($0) == .currencySymbol } } + ["¥", "￥"]
        t.symbols = symbolKeys.stableSorted { $0.netLength > $1.netLength }.map(\.units)
        return t
    }
    static var definitions: [CurrencyDefinition] { tables.definitions }
    static func validCode(_ value: String?) -> Bool { guard let value else { return false }; let u = value.units; return u.count == 3 && u.allSatisfy { $0 >= 65 && $0 <= 90 } }
    static func tryCode(_ value: String) -> CurrencyDefinition? { tables.codes[value] }
    static func byCode(_ value: String) throws -> CurrencyDefinition {
        guard let currency = tryCode(value) else { throw CalcError.arithmetic("Unknown currency code") }
        return currency
    }
    static func symbolLength(_ text: [UInt16], _ position: Int) -> Int {
        for symbol in tables.symbols where position + symbol.count <= text.count && Array(text[position..<(position + symbol.count)]) == symbol { return symbol.count }
        return 0
    }
    static func tryMatch(_ tokens: [Token], _ position: Int) throws -> (currency: CurrencyDefinition, length: Int)? {
        if position >= tokens.count || (tokens[position].kind != .name && tokens[position].kind != .currency) { return nil }
        if tokens[position].text == "¥" || tokens[position].text == "￥" { throw CalcError.format("Ambiguous currency symbol; use JPY or CNY") }
        var count = min(3, tokens.count - position)
        while count > 0 {
            defer { count -= 1 }
            let slice = tokens[position..<(position + count)]
            if slice.contains(where: { $0.kind != .name && $0.kind != .currency }) { continue }
            let name = slice.map(\.text).joined(separator: " ")
            guard let currency = tables.aliases[name] else { continue }
            // Preserve existing physical cup syntax; explicit uppercase CUP means Cuban peso.
            if count == 1 && name != currency.code, try UnitCatalog.tryToken(name) != nil { continue }
            return (currency, count)
        }
        return nil
    }
}
