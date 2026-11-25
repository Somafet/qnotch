import Foundation

struct AtomicWeight: Hashable {
    let atomicNumber: Int, symbol: String, name: String, weight: Rational?, quotedUncertainty: Rational?, notes: String
}
/// CIAAW abridged standard atomic weights (AtomicWeights.json); symbols are case-sensitive.
enum AtomicWeightCatalog {
    private struct Tables {
        var symbols = NetDictionary<String, AtomicWeight>()
        var elements: [AtomicWeight] = []
        var ruleId = "", source = ""
    }
    private static let tables: Tables = {
        do { return try load() } catch { fatalError("Invalid atomic-weight catalog: \(error)") }
    }()
    private static func load() throws -> Tables {
        let root = try JSONNode.parse(CalculatorEngine.resource("AtomicWeights.json"))
        if try root.property("version").int() != 1 { throw CalcError.invalidData("Unsupported atomic-weight catalog") }
        var t = Tables()
        t.ruleId = try root.property("ruleId").string(); t.source = try root.property("source").string()
        for item in try root.property("elements").arrayItems() {
            func read(_ name: String) throws -> Rational? { let value = try item.property(name); return value.isNull ? nil : try Rational.parse(try value.string()) }
            let element = AtomicWeight(atomicNumber: try item.property("atomicNumber").int(), symbol: try item.property("symbol").string(), name: try item.property("name").string(),
                                       weight: try read("weight"), quotedUncertainty: try read("quotedUncertainty"), notes: try item.property("notes").string())
            if element.atomicNumber != t.elements.count + 1 || element.symbol.netLength < 1 || element.symbol.netLength > 2 || element.weight.map({ $0.sign <= 0 }) == true ||
                (element.weight != nil) != (element.quotedUncertainty != nil) {
                throw CalcError.invalidData("Invalid atomic-weight definition")
            }
            if !t.symbols.tryAdd(element.symbol, element) { throw CalcError.argument("An item with the same key has already been added. Key: " + element.symbol) }
            t.elements.append(element)
        }
        if t.elements.count != 118 || t.elements.filter({ $0.weight != nil }).count != 84 { throw CalcError.invalidData("Incomplete atomic-weight catalog") }
        return t
    }
    static var elements: [AtomicWeight] { tables.elements }
    static var ruleId: String { tables.ruleId }
    static var source: String { tables.source }
    static func get(_ symbol: String) throws -> AtomicWeight {
        guard let element = tables.symbols[symbol] else { throw CalcError.arithmetic("Unknown case-sensitive element: " + symbol) }
        return element
    }
}

struct ChemicalContribution: Hashable { let symbol: String, atoms: Int, atomicWeight: Rational, quotedUncertainty: Rational, gramsPerMole: Rational }
/// The parsed formula, catalog rule and per-element contributions behind one molar-mass step.
struct ChemistryEvidence: Hashable { let formula: String, ruleId: String, nominalGramsPerMole: Rational, composition: [ChemicalContribution], source: String }

final class ChemistryArithmetic {
    static let assumption = "Nominal molar mass from CIAAW abridged 2024 weights; natural isotope variation and quoted atomic-weight uncertainties are not propagated; not an exact physical constant, isotope-specific mass or purity model"
    let budget: ExecutionBudget, token: CancellationToken
    init(_ budget: ExecutionBudget, _ token: CancellationToken) { self.budget = budget; self.token = token }
    private func step() throws { try budget.step(token) }

    /// Parses a case-sensitive formula: element symbols with counts, (…) and […] groups with multipliers, and `·`/`.` adducts with a leading count (CuSO4·5H2O).
    func formula(_ input: String) throws -> ChemistryEvidence {
        if input.netLength < 1 || input.netLength > 512 { throw CalcError.arithmetic("Chemical formula must contain 1–512 characters") }
        // Subscript digits ₀…₉ read as digits.
        let text = input.units.map { $0 >= 0x2080 && $0 <= 0x2089 ? 0x30 + $0 - 0x2080 : $0 }
        let limit = 1_000_000
        var position = 0, depth = 0
        func isDigit(_ i: Int) -> Bool { i < text.count && NetChar.isAsciiDigit(text[i]) }
        func count() throws -> Int {
            if !isDigit(position) { return 1 }
            var value = 0
            while isDigit(position) {
                try step(); let digit = Int(text[position]) - 48; position += 1
                if value > 100000 || value * 10 + digit > limit { throw CalcError.arithmetic("Chemical atom/count limit exceeded") }
                value = value * 10 + digit
            }
            if value == 0 { throw CalcError.arithmetic("Chemical counts must be positive integers") }
            return value
        }
        func add(_ output: inout NetDictionary<String, Int>, _ symbol: String, _ count: Int) throws {
            try step(); let total = (output[symbol] ?? 0) + count
            if total > limit { throw CalcError.arithmetic("Chemical atom/count limit exceeded") }
            output.set(symbol, total)
        }
        let dot: UInt16 = 0x2E, middleDot: UInt16 = 0xB7
        func group(_ close: UInt16 = 0) throws -> NetDictionary<String, Int> {
            depth += 1
            if depth > 16 { throw CalcError.arithmetic("Chemical grouping depth exceeds 16") }
            var output = NetDictionary<String, Int>(); var terms = 0
            while position < text.count && text[position] != close && text[position] != dot && text[position] != middleDot {
                try step(); let c = text[position]; position += 1
                if c == 0x28 || c == 0x5B { // ( or [
                    let closing: UInt16 = c == 0x28 ? 0x29 : 0x5D
                    let nested = try group(closing)
                    if position >= text.count { throw CalcError.format("Unclosed chemical group") }
                    let closed = text[position]; position += 1
                    if closed != closing { throw CalcError.format("Unclosed chemical group") }
                    let multiplier = try count()
                    for entry in nested {
                        if entry.value * multiplier > limit { throw CalcError.arithmetic("Chemical atom/count limit exceeded") }
                        try add(&output, entry.key, entry.value * multiplier)
                    }
                } else {
                    if c < 0x41 || c > 0x5A { throw CalcError.format("Chemical elements require case-sensitive symbols and matched groups") }
                    var symbol = [c]
                    if position < text.count && text[position] >= 0x61 && text[position] <= 0x7A { symbol.append(text[position]); position += 1 }
                    let name = symbol.string
                    _ = try AtomicWeightCatalog.get(name); try add(&output, name, try count())
                }
                terms += 1
            }
            depth -= 1
            if terms == 0 { throw CalcError.format("Chemical groups cannot be empty") }
            return output
        }
        var atoms = NetDictionary<String, Int>()
        while position < text.count {
            try step(); let multiplier = try count(); let part = try group()
            for entry in part {
                if entry.value * multiplier > limit { throw CalcError.arithmetic("Chemical atom/count limit exceeded") }
                try add(&atoms, entry.key, entry.value * multiplier)
            }
            if position == text.count { break }
            let separator = text[position]; position += 1
            if separator != dot && separator != middleDot || position == text.count { throw CalcError.format("Invalid chemical adduct separator") }
        }
        if atoms.values.reduce(0, +) > limit { throw CalcError.arithmetic("Chemical formula exceeds one million atoms") }
        var total = Rational.zero; var contributions: [ChemicalContribution] = []
        let ordered = try atoms.map { ($0.key, $0.value, try AtomicWeightCatalog.get($0.key).atomicNumber) }.stableSorted { $0.2 < $1.2 }
        for (symbol, atomCount, _) in ordered {
            try step(); let element = try AtomicWeightCatalog.get(symbol)
            guard let weight = element.weight else { throw CalcError.arithmetic("Standard atomic weight unavailable for " + element.symbol + "; an isotope mass is not guessed") }
            let contribution = try weight * Rational(atomCount); try step(); total = try total + contribution
            contributions.append(ChemicalContribution(symbol: symbol, atoms: atomCount, atomicWeight: weight, quotedUncertainty: element.quotedUncertainty!, gramsPerMole: contribution))
        }
        return ChemistryEvidence(formula: text.string, ruleId: AtomicWeightCatalog.ruleId, nominalGramsPerMole: total, composition: contributions, source: AtomicWeightCatalog.source)
    }
    func evaluate(_ expression: ChemistryExpression, _ input: SheetValue?) throws -> (value: SheetValue, evidence: ChemistryEvidence) {
        let evidence = try formula(expression.formula)
        let grams = try UnitExpression.single(UnitCatalog.byId("g")), moles = try UnitExpression.single(UnitCatalog.byId("mol"))
        guard let input else {
            let molar = NumericValue(ExactNumber(try evidence.nominalGramsPerMole / Rational(1000)), unit: try grams.combine(moles, -1)).with { $0.isApproximate = true }
            return (.number(molar), evidence)
        }
        let number = try input.number
        guard !number.isPercentage, let unit = number.unit, number.isRational, (try number.exact.rational).sign >= 0 else {
            throw CalcError.arithmetic("Chemical conversion requires a nonnegative rational mass or amount-of-substance quantity")
        }
        let mass = Dimension(0, 1, 0, 0, 0, 0, 0, 0), amount = Dimension(0, 0, 0, 0, 0, 1, 0, 0)
        let target = expression.target!; let result: Rational
        try step()
        if unit.dimension == mass && target.dimension == amount { result = try number.exact.rational * Rational(1000) / evidence.nominalGramsPerMole }
        else if unit.dimension == amount && target.dimension == mass { result = try number.exact.rational * evidence.nominalGramsPerMole / Rational(1000) }
        else { throw CalcError.arithmetic("Chemical conversion requires mass ↔ amount of substance; use ordinary unit conversion within one dimension") }
        return (.number(NumericValue(ExactNumber(result), unit: target).with { $0.isApproximate = true; $0.displayDecimalPlaces = 4 }), evidence)
    }
}
