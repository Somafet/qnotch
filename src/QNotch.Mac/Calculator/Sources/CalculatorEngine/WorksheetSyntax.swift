import Foundation

final class PlotExpression: Expression {
    let body: FormulaTerm, text: String, inputs: [Expression], hasDomain: Bool
    /// `inputs` are the formula's sheet names, then the two domain bounds when `hasDomain`.
    init(_ body: FormulaTerm, _ text: String, _ inputs: [Expression], _ hasDomain: Bool) { self.body = body; self.text = text; self.inputs = inputs; self.hasDomain = hasDomain }
    var children: [Expression] { inputs }
}
final class ChartExpression: Expression {
    let kind: ChartKind, data: Expression?
    /// The tag of a data-less chart line, which then charts only the block lines with that tag (like `sum #tag`).
    var tag: String?
    init(_ kind: ChartKind, _ data: Expression?, tag: String? = nil) { self.kind = kind; self.data = data; self.tag = tag }
    func with(tag: String?) -> ChartExpression { ChartExpression(kind, data, tag: tag) }
    var children: [Expression] { data.map { [$0] } ?? [] }
}

/// plot formula [from a to b] and bar|pie|trend|line chart [of] [data]. Anything else is left to the ordinary parser, so prose and labels keep working.
enum WorksheetSyntax {
    static func tryParse(_ tokens: [Token], _ names: NetHashSet<String>, _ token: CancellationToken) throws -> Expression? {
        if tokens.count < 2 || tokens[0].kind != .name || knownPrefix(tokens, names) { return nil }
        let head = tokens[0].text.netLower
        if head == "plot" { return try plot(tokens, names, token) }
        if !tokens[1].text.equalsIgnoreCase("chart") { return nil }
        switch head {
        case "bar": return try chart(.bar, tokens, names, token)
        case "pie": return try chart(.pie, tokens, names, token)
        case "trend", "line": return try chart(.trend, tokens, names, token)
        default: return nil
        }
    }
    /// A sheet variable named like the sentence ("bar", "plot", "bar chart") keeps its meaning.
    private static func knownPrefix(_ tokens: [Token], _ names: NetHashSet<String>) -> Bool {
        var phrase = ""
        var i = 0
        while i < tokens.count && tokens[i].kind == .name && phrase.netLength <= 128 {
            phrase = i == 0 ? tokens[i].text : phrase + " " + tokens[i].text
            if names.contains(phrase) { return true }
            i += 1
        }
        return false
    }
    private static func known(_ name: String, _ names: NetHashSet<String>) -> Bool { names.contains(name) || name.equalsIgnoreCase("prev") || SheetSyntax.isLineReference(name) != nil }
    private static func operand(_ tokens: ArraySlice<Token>, _ names: NetHashSet<String>, _ token: CancellationToken) throws -> Expression? {
        do { return try ExpressionParser(Array(tokens), token, names).parse() }
        catch let e as CalcError where e.isFormat { return nil }
    }
    private static func plot(_ tokens: [Token], _ names: NetHashSet<String>, _ token: CancellationToken) throws -> Expression? {
        var from = -1, to = -1, nesting = 0
        for i in 1..<tokens.count {
            try token.throwIfCancellationRequested(); let word = tokens[i].text
            if word == "(" { nesting += 1 } else if word == ")" { nesting -= 1 }
            else if nesting == 0 && tokens[i].kind == .name {
                if from < 0 && word.equalsIgnoreCase("from") { from = i }
                else if from >= 0 && to < 0 && word.equalsIgnoreCase("to") { to = i }
            }
        }
        if nesting != 0 || from >= 0 && (to <= from + 1 || to == tokens.count - 1) { return nil }
        let formula = Array(tokens[1..<(from < 0 ? tokens.count : from)])
        var inputs = FormulaInputs(); let body: FormulaTerm
        do { body = try FormulaParser.parse(formula, "x", &inputs, names, token) }
        catch let e as CalcError where e.isFormat { return nil }
        // "plot 5" stays a label and "plot twist" stays prose: a plot needs the variable, and every other word must be a sheet name.
        if !FormulaFunctions.dependsOnVariable(body) || inputs.expressions.contains(where: { !known(($0 as! NameExpression).name, names) }) { return nil }
        if from >= 0 {
            guard let lower = try operand(tokens[(from + 1)..<to], names, token), let upper = try operand(tokens[(to + 1)...], names, token) else { return nil }
            inputs.expressions.append(lower); inputs.expressions.append(upper)
        }
        let text = formula.enumerated().map { (i, t) in (i == 0 || t.joinedToPrevious ? "" : " ") + t.text }.joined()
        return PlotExpression(body, text, inputs.expressions, from >= 0)
    }
    private static func chart(_ kind: ChartKind, _ tokens: [Token], _ names: NetHashSet<String>, _ token: CancellationToken) throws -> Expression? {
        let start = 2 + (tokens.count > 2 && KeywordCatalog.isOf(tokens[2].text) ? 1 : 0)
        if start == tokens.count { return start == 2 ? ChartExpression(kind, nil) : nil }
        // The rest is data only if it is a list, a known name or a call, so "bar chart monthly" and "bar chart 5" stay as they were.
        guard let data = try operand(tokens[start...], names, token), data is ListExpression || data is NameExpression || data is CallExpression else { return nil }
        return ExpressionEvaluation.walk(data).compactMap { $0 as? NameExpression }.allSatisfy { known($0.name, names) } ? ChartExpression(kind, data) : nil
    }
    /// A chart label: the line's variable, its leading quoted or prose label, or its line reference.
    static func label(_ line: ParsedLine, _ source: String, _ index: Int, _ token: CancellationToken) throws -> String {
        if let name = line.assignment { return name }
        let quoted = source.netTrimStart.units
        if quoted.first == 0x22, let end = quoted.dropFirst().firstIndex(of: 0x22), end > 1 { return String(units: quoted[1..<end]) }
        let tokens: [Token]
        do { tokens = try ExpressionParser.tokenize(line.text, token) }
        catch let e as CalcError where e.isFormat { return "L\(index + 1)" }
        let words = tokens.prefix { $0.kind == .name }
        return !words.isEmpty && (words.count == tokens.count || !tokens[words.count].text.ordinalEquals("(")) ? words.map(\.text).joined(separator: " ") : "L\(index + 1)"
    }
}
