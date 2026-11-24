import Foundation

enum ConstantExactness { case exact, truncated, measured }

/// One pinned constant. Value is a decimal in the stated SI unit; names are space-separated, case-sensitive aliases.
struct ConstantEntry {
    let title: String, names: String, value: String, unit: String
    let exactness: ConstantExactness
    let source: String
    var uncertainty: String? = nil
    var assumption: String { title + (uncertainty.map { ", standard uncertainty " + $0 + " " + unit } ?? "") + "; " + source }
}

/// Pinned offline constants: CODATA 2022 and exact SI 2019 definitions. Units, user variables and the older grammar win over every alias here.
enum ConstantCatalog {
    private static let si = "exact by the 2019 SI definition", codata = "CODATA 2022 (NIST); measured", mathematical = "Mathematical constant to 15 significant digits"
    static let formulaNote = "; SI magnitude; formulas do not track dimensions"
    private static let notationDigits = 15, notationBits = 96
    static let entries: [ConstantEntry] = [
        ConstantEntry(title: "Speed of light in vacuum", names: "c speed_of_light lightspeed", value: "299792458", unit: "m/s", exactness: .exact, source: si),
        ConstantEntry(title: "Planck constant", names: "planck planck_constant", value: "6.62607015e-34", unit: "J*s", exactness: .exact, source: si),
        ConstantEntry(title: "Reduced Planck constant h/2pi", names: "hbar ħ ℏ reduced_planck", value: "1.054571817646156391262428003e-34", unit: "J*s", exactness: .truncated, source: "exact by definition but irrational; CODATA 2022; truncated to 28 digits"),
        ConstantEntry(title: "Elementary charge", names: "elementary_charge e_charge q_e", value: "1.602176634e-19", unit: "C", exactness: .exact, source: si),
        ConstantEntry(title: "Boltzmann constant", names: "boltzmann boltzmann_constant k_B", value: "1.380649e-23", unit: "J/deltaK", exactness: .exact, source: si),
        ConstantEntry(title: "Avogadro constant", names: "avogadro avogadro_constant N_A", value: "6.02214076e23", unit: "/mol", exactness: .exact, source: si),
        ConstantEntry(title: "Molar gas constant N_A*k", names: "gas_constant molar_gas_constant", value: "8.31446261815324", unit: "J/deltaK/mol", exactness: .exact, source: "exact product of two 2019 SI definitions"),
        ConstantEntry(title: "Newtonian constant of gravitation", names: "gravitational_constant newton_constant G_N", value: "6.67430e-11", unit: "m^3/kg/s^2", exactness: .measured, source: codata, uncertainty: "0.00015e-11"),
        ConstantEntry(title: "Standard acceleration of gravity", names: "standard_gravity g0 g_n", value: "9.80665", unit: "m/s^2", exactness: .exact, source: "exact by the 1901 CGPM definition"),
        ConstantEntry(title: "Vacuum electric permittivity", names: "vacuum_permittivity epsilon0 eps0 ε0 ε₀", value: "8.8541878188e-12", unit: "F/m", exactness: .measured, source: codata, uncertainty: "0.0000000014e-12"),
        ConstantEntry(title: "Vacuum magnetic permeability", names: "vacuum_permeability mu0 μ0 µ0 μ₀", value: "1.25663706127e-6", unit: "N/A^2", exactness: .measured, source: codata, uncertainty: "0.00000000020e-6"),
        ConstantEntry(title: "Electron mass", names: "electron_mass m_e", value: "9.1093837139e-31", unit: "kg", exactness: .measured, source: codata, uncertainty: "0.0000000028e-31"),
        ConstantEntry(title: "Proton mass", names: "proton_mass m_p", value: "1.67262192595e-27", unit: "kg", exactness: .measured, source: codata, uncertainty: "0.00000000052e-27"),
        ConstantEntry(title: mathematical, names: "pi π", value: "3.14159265358979", unit: "", exactness: .truncated, source: "approximate"),
        ConstantEntry(title: mathematical, names: "tau τ", value: "6.28318530717959", unit: "", exactness: .truncated, source: "approximate"),
        ConstantEntry(title: mathematical, names: "e", value: "2.71828182845905", unit: "", exactness: .truncated, source: "approximate"),
        ConstantEntry(title: "Golden ratio (1 + sqrt(5))/2", names: "phi φ", value: "phi", unit: "", exactness: .exact, source: "exact radical; display rounded to 15 significant digits")
    ]
    private static let names: [String: ConstantEntry] = {
        var map: [String: ConstantEntry] = [:]
        for entry in entries { for name in entry.names.netSplit(" ") { precondition(map[name] == nil); map[name] = entry } }
        return map
    }()
    static func tryFind(_ name: String) -> ConstantEntry? { names[name] ?? (FormulaFunctions.isConstant(name) ? names[name.netLower] : nil) }
    static func isPhysical(_ name: String) -> Bool { (names[name]?.unit.isEmpty == false) }
    /// A lone word that evaluates instead of staying prose. Foundation keeps a lone e as prose.
    static func isLoneValue(_ name: String) -> Bool { name == "i" || name != "e" && names[name] != nil }
    /// "c in mph" is all name tokens, so it reads as prose unless the target unit fits the constant.
    static func isConversionLine(_ tokens: [Token]) throws -> Bool {
        guard tokens.count >= 3, tokens[1].text == "in" || tokens[1].text == "to", let entry = names[tokens[0].text], !entry.unit.isEmpty else { return false }
        var position = 2
        guard let unit = try UnitParser.tryParse(tokens, &position, nil) else { return false }
        return try position == tokens.count && unit.dimension == self.unit(entry).dimension
    }
    /// "pi to 3 decimals" would otherwise lose "pi to" as a leading label before the number.
    static func isRoundingLine(_ tokens: [Token]) -> Bool {
        if tokens.count < 3 || tokens[0].text != "i" && tryFind(tokens[0].text) == nil { return false }
        let to = KeywordCatalog.match(tokens, 1, .to)
        return to > 0 && (KeywordCatalog.match(tokens, 1 + to, .nearest) > 0 || KeywordCatalog.match(tokens, 2 + to, .decimals) > 0 || KeywordCatalog.match(tokens, 2 + to, .significant) > 0)
    }
    private static func unit(_ entry: ConstantEntry) throws -> UnitExpression {
        var position = 0
        guard let unit = try UnitParser.tryParse(ExpressionParser.tokenize(entry.unit, .none), &position, nil) else { throw CalcError.invalidData("Invalid constant unit: " + entry.unit) }
        return unit
    }
    private static func decimal(_ text: String) throws -> Rational {
        let split = text.netIndexOf("e")
        if split < 0 { return try Rational.parse(text) }
        let exponent = Int(text.netSubstring(split + 1))!; let scale = BigInt.pow(10, abs(exponent))
        return try Rational.parse(text.netSubstring(0, split)) * (exponent < 0 ? try Rational(.one, scale) : try Rational(scale))
    }
    /// The value with its unit and notation; a formula takes the plain SI magnitude.
    static func resolve(_ entry: ConstantEntry, _ magnitude: Bool) throws -> NumericValue {
        let exact = entry.value == "phi" ? try phi() : ExactNumber(try decimal(entry.value))
        let value = entry.unit.isEmpty || magnitude ? NumericValue(exact) : NumericValue(exact, unit: try unit(entry))
        return value.with { $0.isApproximate = entry.exactness != .exact; $0.useConstantNotation = !magnitude }
    }
    private static func phi() throws -> ExactNumber { try ExactNumber(terms: [.one: Rational(1, 2), BigInt(5): Rational(1, 2)]) }
    /// Comma-grouped decimal for everyday magnitudes, scientific otherwise, at most 15 significant digits. Reports rounding so the caller can mark it.
    static func notation(_ value: ExactNumber, _ math: ExactArithmetic, _ rounded: inout Bool) throws -> String {
        let rational = value.isRational ? value.constant : try math.bounds(value, notationBits).lower
        rounded = !value.isRational
        if rational.isZero { return "0" }
        let n = rational.numerator.magnitude, d = rational.denominator
        var exponent = n.description.count - d.description.count
        if exponent >= 0 ? n < d * BigInt.pow(10, exponent) : n * BigInt.pow(10, -exponent) < d { exponent -= 1 }
        let shift = notationDigits - 1 - exponent
        let top = shift >= 0 ? n * BigInt.pow(10, shift) : n, bottom = shift >= 0 ? d : d * BigInt.pow(10, -shift)
        var scaled = (2 * top + bottom) / (2 * bottom)
        rounded = rounded || scaled * bottom != top
        if scaled == BigInt.pow(10, notationDigits) { scaled = scaled / 10; exponent += 1 }
        let digits = scaled.description.netTrimEnd("0")
        let sign = rational.sign < 0 ? "-" : ""
        if exponent < -3 || exponent >= notationDigits {
            return sign + String(digits.prefix(1)) + (digits.count > 1 ? "." + digits.dropFirst() : "") + "e" + String(exponent)
        }
        if exponent < 0 { return sign + "0." + String(repeating: "0", count: -exponent - 1) + digits }
        let whole = digits.count > exponent ? String(digits.prefix(exponent + 1)) : digits.netPadRight(exponent + 1, "0")
        return sign + groupThousands(whole) + (digits.count > exponent + 1 ? "." + digits.dropFirst(exponent + 1) : "")
    }
    /// long.Parse(text).ToString("N0", InvariantCulture) for a digit string.
    static func groupThousands(_ digits: String) -> String {
        let trimmed = String(digits.drop(while: { $0 == "0" })); let text = trimmed.isEmpty ? "0" : trimmed
        var out = ""
        for (i, c) in text.enumerated() { if i > 0 && (text.count - i) % 3 == 0 { out += "," }; out.append(c) }
        return out
    }
}
