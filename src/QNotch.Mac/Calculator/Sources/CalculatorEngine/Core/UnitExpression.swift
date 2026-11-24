import Foundation

/// Immutable display unit; the canonical magnitude is stored separately in NumericValue.exact.
final class UnitExpression: Hashable, CustomStringConvertible {
    typealias Term = (unit: UnitDefinition, power: Int)
    private let terms: [Term]
    let dimension: Dimension
    let factor: Rational
    let offset: Rational
    let isTemperaturePoint: Bool
    let symbol: String
    let kind: String
    let key: String

    private init(_ values: [Term]) throws {
        terms = values.filter { $0.power != 0 }.stableSorted { String.ordinalCompare($0.unit.id, $1.unit.id) < 0 }
        if terms.count > 16 || terms.contains(where: { abs($0.power) > 16 }) { throw CalcError.arithmetic("Unit expression limit exceeded") }
        isTemperaturePoint = terms.contains { $0.unit.isTemperaturePoint }
        if isTemperaturePoint && (terms.count != 1 || terms[0].power != 1) { throw CalcError.arithmetic("Absolute temperature cannot form a compound unit; use delta units") }
        var dimension = Dimension.none, factor = Rational.one
        for term in terms {
            dimension = try dimension.combine(term.unit.dimension.power(Rational(term.power)), 1)
            for _ in 0..<abs(term.power) { factor = term.power > 0 ? try factor * term.unit.factor : try factor / term.unit.factor }
        }
        self.dimension = dimension; self.factor = factor
        offset = isTemperaturePoint ? terms[0].unit.offset : .zero
        kind = terms.count == 1 && terms[0].power == 1 ? terms[0].unit.kind : ""
        key = terms.map { $0.unit.id + ":" + String($0.power) }.joined(separator: ";")
        func part(_ term: Term) -> String { term.unit.symbol + (abs(term.power) == 1 ? "" : "^" + String(abs(term.power))) }
        let numerator = terms.filter { $0.power > 0 }.map(part).joined(separator: "*")
        let denominator = terms.filter { $0.power < 0 }
        symbol = numerator.isEmpty && !denominator.isEmpty
            ? denominator.map { $0.unit.symbol + "^" + String($0.power) }.joined(separator: "*")
            : (numerator.isEmpty ? "1" : numerator) + denominator.map { "/" + part($0) }.joined()
        if symbol.netLength > 256 { throw CalcError.arithmetic("Unit output limit exceeded") }
    }
    static func single(_ unit: UnitDefinition) throws -> UnitExpression { try UnitExpression([(unit, 1)]) }
    func combine(_ other: UnitExpression, _ sign: Int) throws -> UnitExpression {
        if isTemperaturePoint || other.isTemperaturePoint { throw CalcError.arithmetic("Absolute temperature cannot form a compound unit; use delta units") }
        var values = NetDictionary<String, Term>()
        for term in terms { values.set(term.unit.id, term) }
        for term in other.terms { values.set(term.unit.id, (term.unit, (values[term.unit.id]?.power ?? 0) + sign * term.power)) }
        // Equivalent linear units cancel by dimension, even when their scales differ (s * km/h).
        // Magnitude is canonical already; recomputing the chosen display factor preserves exactness.
        struct GroupKey: Hashable { let dimension: Dimension; let kind: String }
        var groups = NetDictionary<GroupKey, [Term]>()
        for value in values.values { let k = GroupKey(dimension: value.unit.dimension, kind: value.unit.kind); groups.set(k, (groups[k] ?? []) + [value]) }
        var simplified: [Term] = []
        for group in groups.values {
            let power = group.reduce(0) { $0 + $1.power }
            var preferred = group[0].unit
            for value in group where try (value.unit.factor - preferred.factor).sign > 0 { preferred = value.unit }
            if power != 0 { simplified.append((preferred, power)) }
        }
        return try UnitExpression(simplified)
    }
    func power(_ exponent: Rational) throws -> UnitExpression {
        if isTemperaturePoint && exponent != .one { throw CalcError.arithmetic("Absolute temperature cannot be raised to a power") }
        let dimension = try self.dimension.power(exponent)
        let powers = try terms.map { ($0.unit, try Rational($0.power) * exponent) }
        return powers.allSatisfy({ $0.1.denominator.isOne }) ? try UnitExpression(powers.map { ($0.0, $0.1.numerator.intValue!) }) : try UnitExpression.canonical(dimension)
    }
    /// 1 for fuel consumption (volume per distance: l/100km, L/km), -1 for fuel economy (distance per volume: mpg, km/l), otherwise 0.
    func fuelForm() -> Int {
        if terms.count == 1 {
            if terms[0].power != 1 { return 0 }
            switch terms[0].unit.id { case "l100km": return 1; case "mpg", "mpguk": return -1; default: return 0 }
        }
        if terms.count != 2 || terms[0].power * terms[1].power != -1 { return 0 }
        let volume = terms.filter { $0.unit.dimension == UnitExpression.fuelVolumeDimension }
        return volume.count == 1 && terms.contains(where: { $0.unit.dimension == UnitExpression.fuelLengthDimension }) ? volume[0].power : 0
    }
    private static let fuelVolumeDimension = Dimension(3, 0, 0, 0, 0, 0, 0, 0), fuelLengthDimension = Dimension(1, 0, 0, 0, 0, 0, 0, 0)
    /// The volume unit a trip over this consumption is reported in: litre, US gallon or imperial gallon, or the unit's own volume term.
    func fuelVolume() throws -> UnitExpression {
        if terms.count == 1 {
            let id: String
            switch terms[0].unit.id { case "mpg": id = "gal"; case "mpguk": id = "impgal"; default: id = "L" }
            return try .single(UnitCatalog.byId(id))
        }
        return try .single(terms.first { $0.unit.dimension == UnitExpression.fuelVolumeDimension }!.unit)
    }
    func delta() throws -> UnitExpression {
        if !isTemperaturePoint { return self }
        return try .single(UnitCatalog.byId("delta" + terms[0].unit.id.netReplace("deg", "")))
    }
    static func canonical(_ dimension: Dimension) throws -> UnitExpression {
        let bases = ["m", "kg", "s", "A", "deltaK", "mol", "cd", "bit"]
        return try UnitExpression(dimension.components.enumerated().map { (UnitCatalog.byId(bases[$0.offset]), $0.element) })
    }
    static func == (a: UnitExpression, b: UnitExpression) -> Bool { a.key == b.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    var description: String { symbol }
    func moneySuffix() -> String {
        func part(_ term: Term) -> String { term.unit.symbol + (abs(term.power) == 1 ? "" : "^" + String(abs(term.power))) }
        let numerator = terms.filter { $0.power > 0 }.map(part).joined(separator: "*")
        return (numerator.isEmpty ? "" : " " + numerator) + terms.filter { $0.power < 0 }.map { "/" + part($0) }.joined()
    }
}

/// C# `a == b` on nullable UnitExpression (both null are equal).
func sameUnit(_ a: UnitExpression?, _ b: UnitExpression?) -> Bool { a?.key == b?.key }
