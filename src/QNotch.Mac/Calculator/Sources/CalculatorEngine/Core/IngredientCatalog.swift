import Foundation

/// Grams per US customary cup of one ingredient, with the source of that number. An estimate for the ingredient as commonly measured, not a property of a sample.
struct IngredientDefinition: Hashable { let id: String, gramsPerCup: Rational, source: String, note: String, names: [String] }

/// Pinned, bounded ingredient densities (`Ingredients.json`, rebuilt by `tools/build-ingredient-catalog.py` from a retained USDA extract).
enum IngredientCatalog {
    static let maxWords = 4
    private struct Tables {
        var names = NetDictionary<String, IngredientDefinition>()
        var ingredients: [IngredientDefinition] = []
        var basis = "", dataset = ""
    }
    private static let tables: Tables = {
        do { return try load() } catch { fatalError("Invalid ingredient catalog: \(error)") }
    }()
    private static func load() throws -> Tables {
        let root = try JSONNode.parse(CalculatorEngine.resource("Ingredients.json"))
        if try root.property("version").int() != 1 { throw CalcError.invalidData("Unsupported ingredient catalog") }
        var t = Tables()
        t.basis = try root.property("basis").string()
        let dataset = try root.property("dataset"); t.dataset = try dataset.property("name").string() + " (" + (try dataset.property("file").string()) + ")"
        for item in try root.property("ingredients").arrayItems() {
            let aliases = try item.property("names").arrayItems().map { try $0.string() }
            let definition = IngredientDefinition(id: try item.property("id").string(), gramsPerCup: try Rational.parse(try item.property("gramsPerCup").string()),
                                                  source: try item.property("source").string(), note: try item.optionalProperty("note")?.string() ?? "", names: aliases)
            if try definition.source.isEmpty || definition.gramsPerCup.sign <= 0 || definition.gramsPerCup.above(Rational(1000)) || aliases.isEmpty {
                throw CalcError.invalidData("Invalid ingredient definition")
            }
            for alias in aliases {
                if alias.isEmpty || alias.netLength > 64 || !alias.ordinalEquals(alias.netLower) || alias.netSplit(" ").count > maxWords || !t.names.tryAdd(alias, definition) {
                    throw CalcError.invalidData("Invalid ingredient name: " + alias)
                }
            }
            t.ingredients.append(definition)
        }
        if t.ingredients.isEmpty || t.ingredients.count > 128 { throw CalcError.invalidData("Ingredient catalog limit exceeded") }
        return t
    }
    static var ingredients: [IngredientDefinition] { tables.ingredients }
    static var basis: String { tables.basis }
    static var dataset: String { tables.dataset }
    /// Case-insensitive, with runs of white space read as one space.
    static func tryGet(_ name: String) -> IngredientDefinition? { tables.names[name.netLower.netSplitWhiteSpace.joined(separator: " ")] }
    /// The longest ingredient name starting at `start`, and the number of tokens it spans; a hyphen between words reads as a space.
    static func tryMatch(_ tokens: [Token], _ start: Int) -> (definition: IngredientDefinition, length: Int)? {
        var words: [String] = [], ends: [Int] = []
        var index = start
        while index < tokens.count && words.count < maxWords {
            defer { index += 1 }
            if tokens[index].text == "-" && !words.isEmpty && index + 1 < tokens.count && tokens[index + 1].kind == .name { continue }
            if tokens[index].kind != .name { break }
            words.append(tokens[index].text.netLower); ends.append(index + 1 - start)
        }
        var count = words.count
        while count > 0 {
            if let definition = tables.names[words.prefix(count).joined(separator: " ")] { return (definition, ends[count - 1]) }
            count -= 1
        }
        return nil
    }
}
