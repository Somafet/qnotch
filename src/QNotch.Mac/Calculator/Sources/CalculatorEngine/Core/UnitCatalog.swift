import Foundation

final class UnitDefinition: Hashable {
    let id: String, symbol: String
    let dimension: Dimension
    let factor: Rational, offset: Rational
    let isTemperaturePoint: Bool
    let source: String
    let kind: String
    init(id: String, symbol: String, dimension: Dimension, factor: Rational, offset: Rational, isTemperaturePoint: Bool, source: String, kind: String) {
        self.id = id; self.symbol = symbol; self.dimension = dimension; self.factor = factor; self.offset = offset
        self.isTemperaturePoint = isTemperaturePoint; self.source = source; self.kind = kind
    }
    static func == (a: UnitDefinition, b: UnitDefinition) -> Bool {
        a.id == b.id && a.symbol == b.symbol && a.dimension == b.dimension && a.factor == b.factor && a.offset == b.offset && a.isTemperaturePoint == b.isTemperaturePoint && a.source == b.source && a.kind == b.kind
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Bounded, versioned exact definitions. Symbols preserve case; full names ignore case.
enum UnitCatalog {
    private struct Tables {
        var symbols: [String: UnitDefinition] = [:]
        var names = NetDictionary<String, UnitDefinition>.ignoringCase()
        var ids: [String: UnitDefinition] = [:]
        var units: [UnitDefinition] = []
    }
    private static let tables: Tables = {
        do { return try load() } catch { fatalError("Invalid unit catalog: \(error)") }
    }()
    private static func load() throws -> Tables {
        let root = try JSONNode.parse(CalculatorEngine.resource("Units.json"))
        if try root.property("version").int() != 1 { throw CalcError.invalidData("Unsupported unit catalog") }
        let sources = try root.property("sources")
        var t = Tables()
        func add(_ key: String, _ value: UnitDefinition, names: Bool) throws {
            if key.isEmpty || key.netLength > 64 || key.utf16.contains(where: NetChar.isWhiteSpace) { throw CalcError.invalidData("Invalid unit alias") }
            let old = names ? t.names[key] : t.symbols[key]
            if let old, old != value { throw CalcError.invalidData("Ambiguous unit alias: " + key) }
            if names { t.names.set(key, value) } else { t.symbols[key] = value }
        }
        for item in try root.property("units").arrayItems() {
            let id = try item.property("id").string(), symbol = try item.property("symbol").string()
            let dimension = try Dimension.from(try item.property("dimension").arrayItems().map { try $0.int() })
            let factor = try parseFactor(try item.property("factor").string())
            let offset = try item["offset"].map { try parseFactor(try $0.string()) } ?? .zero
            let point = try item["point"]?.bool() ?? false
            if id.isEmpty || id.netLength > 32 || symbol.isEmpty || symbol.netLength > 32 || factor.sign <= 0 ||
                (point && dimension != Dimension(0, 0, 0, 0, 1, 0, 0, 0)) || (!point && !offset.isZero) { throw CalcError.invalidData("Invalid unit definition") }
            let kind = try item["kind"]?.string() ?? ""
            if !["", "absorbedDose", "equivalentDose", "frequency", "activity"].contains(kind) { throw CalcError.invalidData("Invalid quantity kind") }
            let definition = UnitDefinition(id: id, symbol: symbol, dimension: dimension, factor: factor, offset: offset, isTemperaturePoint: point,
                                            source: try sources.property(try item.property("source").string()).string(), kind: kind)
            if t.ids[id] != nil { throw CalcError.argument("An item with the same key has already been added. Key: " + id) }
            t.ids[id] = definition; t.units.append(definition)
            for alias in try item.property("symbols").arrayItems() { try add(try alias.string(), definition, names: false) }
            for alias in try item.property("names").arrayItems() { try add(try alias.string(), definition, names: true) }
        }
        if t.units.count > 512 || t.symbols.count + t.names.count > 4096 { throw CalcError.invalidData("Unit catalog limit exceeded") }
        return t
    }
    private static func parseFactor(_ value: String) throws -> Rational {
        let parts = value.netSplit("/")
        if parts.count < 1 || parts.count > 2 { throw CalcError.invalidData("Invalid unit factor") }
        return parts.count == 1 ? try Rational.parse(value) : try Rational.parse(parts[0]) / Rational.parse(parts[1])
    }
    static var units: [UnitDefinition] { tables.units }
    static func byId(_ id: String) -> UnitDefinition { tables.ids[id]! }
    static func tryGet(_ text: String) -> UnitDefinition? { tables.symbols[text] ?? tables.names[text] }
    static func tryToken(_ text: String) throws -> UnitExpression? {
        if let speed = try RateSyntax.trySpeedUnit(text) { return speed }
        if let definition = tryGet(text) { return try UnitExpression.single(definition) }
        let u = text.units
        if u.count > 1, let last = u.last, [0x32, 0x33, 0xB2, 0xB3].contains(last), let definition = tryGet(u.string(0, u.count - 1)) {
            return try UnitExpression.single(definition).power(Rational(last == 0x32 || last == 0xB2 ? 2 : 3))
        }
        return nil
    }
    static func canonicalToken(_ tokens: [Token], _ index: Int, _ parameters: NetHashSet<String>) throws -> String? {
        if tokens[index].kind != .name || parameters.contains(tokens[index].text) || index + 1 < tokens.count && tokens[index + 1].text == "(" { return nil }
        return try tryToken(tokens[index].text).map { "@UNIT:" + $0.key }
    }
    static func symbolLength(_ source: [UInt16], _ start: Int) -> Int {
        if source[start] != 0xB0 { return 0 }
        return start + 1 < source.count && [0x43, 0x46, 0x52].contains(source[start + 1]) ? 2 : 0
    }
}
