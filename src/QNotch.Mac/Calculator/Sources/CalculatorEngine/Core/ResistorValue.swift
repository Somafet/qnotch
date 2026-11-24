import Foundation

/// One commercial colour band: its significant digit (gold and silver have none), multiplier exponent and tolerance (C# ResistorColorDefinition).
struct ResistorColorDefinition: Hashable {
    let name: String, digit: Int?, multiplierExponent: Int, tolerance: Rational?
}

/// Pinned commercial markings; never fetches rules or infers a physical component's orientation.
enum ResistorColorCatalog {
    private struct Tables {
        var names = NetDictionary<String, ResistorColorDefinition>.ignoringCase()
        var colors: [ResistorColorDefinition] = []
        var ruleId = "", source = ""
    }
    private static let tables: Tables = {
        do { return try load() } catch { fatalError("Invalid resistor color catalog: \(error)") }
    }()
    private static func load() throws -> Tables {
        let root = try JSONNode.parse(CalculatorEngine.resource("ResistorColors.json"))
        if try root.property("version").int() != 1 { throw CalcError.invalidData("Unsupported resistor color catalog") }
        var t = Tables()
        t.ruleId = try root.property("ruleId").string(); t.source = try root.property("source").string()
        for item in try root.property("colors").arrayItems() {
            let digit = try item.property("digit"), tolerance = try item.property("tolerancePercent")
            let color = ResistorColorDefinition(name: try item.property("name").string(), digit: digit.isNull ? nil : try digit.int(),
                                                multiplierExponent: try item.property("multiplierExponent").int(),
                                                tolerance: tolerance.isNull ? nil : try Rational.parse(try tolerance.string()) / Rational(100))
            if color.name.netLength < 1 || color.name.netLength > 16 || color.digit.map({ $0 < 0 || $0 > 9 }) == true ||
                color.multiplierExponent < -2 || color.multiplierExponent > 9 || color.tolerance.map({ $0.sign <= 0 }) == true {
                throw CalcError.invalidData("Invalid resistor color definition")
            }
            if !t.names.tryAdd(color.name, color) { throw CalcError.argument("An item with the same key has already been added. Key: " + color.name) }
            t.colors.append(color)
        }
        if t.colors.count != 12 || t.colors.filter({ $0.digit != nil }).count != 10 { throw CalcError.invalidData("Incomplete resistor colors") }
        if !t.names.tryAdd("grey", t.names["gray"]!) { throw CalcError.argument("An item with the same key has already been added. Key: grey") }
        return t
    }
    static var colors: [ResistorColorDefinition] { tables.colors }
    static var ruleId: String { tables.ruleId }
    static var source: String { tables.source }
    /// Case-insensitive; "grey" is an alias of "gray".
    static func tryGet(_ name: String) -> ResistorColorDefinition? { tables.names[name] }
}

/// Immutable physical marking with nominal magnitude and stated component tolerance, not a measured resistance.
final class ResistorValue: Hashable, CustomStringConvertible {
    let nominalOhms: Rational
    let tolerance: Rational
    let significantDigits: Int
    let bands: [String]
    let showColors: Bool
    let nominal: NumericValue
    var minimumOhms: Rational { get throws { try nominalOhms * (Rational.one - tolerance) } }
    var maximumOhms: Rational { get throws { try nominalOhms * (Rational.one + tolerance) } }

    init(_ ohms: Rational, _ tolerance: Rational, _ bands: [String], _ digits: Int, _ showColors: Bool) throws {
        nominalOhms = ohms; self.tolerance = tolerance; significantDigits = digits; self.bands = bands; self.showColors = showColors
        let unit = try (ohms - Rational(1_000_000)).sign >= 0 ? "Mohm" : (ohms - Rational(1000)).sign >= 0 ? "kohm" : "ohm"
        nominal = NumericValue(ExactNumber(ohms), unit: try .single(UnitCatalog.byId(unit)))
    }
    var display: String { get throws { showColors ? bands.joined(separator: " ") : try nominal.display + " ±" + (try tolerance * Rational(100)).description + "%" } }
    /// Both modes round-trip the actual marking, including significant digits and tolerance.
    var copyText: String {
        get throws {
            showColors ? bands.joined(separator: " ")
                : "resistor(" + nominalOhms.description + " ohm," + (try tolerance * Rational(100)).description + "%," + String(significantDigits) + ")"
        }
    }
    static func == (a: ResistorValue, b: ResistorValue) -> Bool {
        a === b || a.nominalOhms == b.nominalOhms && a.tolerance == b.tolerance && a.significantDigits == b.significantDigits && a.showColors == b.showColors &&
            a.bands.elementsEqual(b.bands, by: { $0.ordinalEquals($1) })
    }
    func hash(into hasher: inout Hasher) { hasher.combine(nominalOhms); hasher.combine(tolerance); hasher.combine(significantDigits); hasher.combine(showColors) }
    var description: String { (try? display) ?? "" }
}
