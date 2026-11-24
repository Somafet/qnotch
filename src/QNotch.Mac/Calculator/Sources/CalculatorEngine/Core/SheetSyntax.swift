import Foundation

struct ParsedLine {
    var text: String
    var assignment: String?
    var tags: [String]
    var boundary: Bool
    var expression: Expression?
    var error: String?
    var directive: FunctionDirective?
    var functionName: String?
    init(_ text: String, _ assignment: String?, _ tags: [String], _ boundary: Bool, _ expression: Expression?, _ error: String?) {
        self.text = text; self.assignment = assignment; self.tags = tags; self.boundary = boundary; self.expression = expression; self.error = error
    }
    func with(_ change: (inout ParsedLine) -> Void) -> ParsedLine { var copy = self; change(&copy); return copy }
}

/// C# `tags.Distinct(StringComparer.OrdinalIgnoreCase)`: first spelling of each, in order.
func distinctIgnoringCase(_ items: [String]) -> [String] { NetHashSet.ignoringCase(items).elements }

enum SheetSyntax {
    static func normalizeName(_ name: String) -> String { name.netSplitWhiteSpace.joined(separator: " ") }
    static func isReserved(_ name: String) -> Bool {
        name.equalsIgnoreCase("prev") || name.equalsIgnoreCase("sum") || name.equalsIgnoreCase("average") || isLineReference(name) != nil
    }
    static func validName(_ name: String) -> Bool {
        let length = name.netLength
        guard length > 0, length <= 128, !isReserved(name) else { return false }
        return name.netSplit(" ").allSatisfy { w in
            let u = w.units
            guard let first = u.first else { return false } // C# would throw on w[0]; an empty word only comes from double spaces, which NormalizeName removes
            return (NetChar.isLetter(first) || first == 0x5F) && u.allSatisfy { NetChar.isLetterOrDigit($0) || $0 == 0x5F || KeywordCatalog.isMark($0) }
        }
    }
    /// IsLineReference: nil when not a line reference; the zero-based index (or -1 when the number overflows) otherwise.
    static func isLineReference(_ name: String) -> Int? {
        let u = name.units
        if u.count < 2 || NetChar.upper(u[0]) != 0x4C || !u[1...].allSatisfy(NetChar.isAsciiDigit) { return nil }
        guard let number = Int32(String(units: u[1...])) else { return -1 }
        return Int(number) - 1
    }
    static func scan(_ original: String, _ cancellationToken: CancellationToken = .none) throws -> ParsedLine {
        let trimmed = original.netTrim
        if trimmed.isEmpty || trimmed.hasPrefix("# ") || trimmed == "#" { return ParsedLine("", nil, [], true, nil, nil) }
        let normalized: String
        do { normalized = try TextSyntax.normalizeNatural(original, cancellationToken) }
        catch let e as CalcError where e.isFormatOrArithmetic { return ParsedLine("", nil, [], false, nil, e.message).with { $0.functionName = TextSyntax.attemptedDefinitionName(original) } }
        let line = normalized.units
        var dataCalls: [Bool]? = line.contains(0x22) ? [] : nil
        var text: [UInt16] = []; var tags: [String] = []
        var quoted = false
        var i = 0
        while i < line.count {
            defer { i += 1 }
            if i & 255 == 0 { try cancellationToken.throwIfCancellationRequested() }
            let c = line[i]
            if !quoted && c == 0x22, let data = dataCalls?.last, data {
                var end = i
                do { _ = try TextSyntax.readQuoted(line, &end, cancellationToken) }
                catch let e as CalcError where e.isFormatOrArithmetic { return ParsedLine("", nil, [], false, nil, e.message).with { $0.functionName = TextSyntax.attemptedDefinitionName(normalized) } }
                text.append(contentsOf: line[i..<end]); i = end - 1; continue
            }
            if quoted && c == 0x5C && i + 1 < line.count { i += 1; continue }
            if c == 0x22 { quoted.toggle(); text.append(0x20); continue }
            if quoted { continue }
            if c == 0x28, dataCalls != nil { dataCalls!.append((dataCalls!.last ?? false) || TextSyntax.dataCallAt(line, i)) }
            else if c == 0x29, dataCalls != nil, !dataCalls!.isEmpty { dataCalls!.removeLast() }
            if c == 0x2F && i + 1 < line.count && line[i + 1] == 0x2F { break }
            if c == 0x23, case let colourLength = DeveloperSyntax.colourLiteralLength(line, i), colourLength > 0 { text.append(contentsOf: line[i..<(i + colourLength)]); i += colourLength - 1; continue }
            if c == 0x23 {
                i += 1; let start = i
                while i < line.count && (NetChar.isLetterOrDigit(line[i]) || line[i] == 0x5F || line[i] == 0x2D || KeywordCatalog.isMark(line[i])) { i += 1 }
                if start == i || i - start > 64 { return ParsedLine("", nil, [], false, nil, "Invalid tag") }
                tags.append(line.string(start, i)); text.append(0x20); i -= 1; continue
            }
            text.append(c)
        }
        if quoted { return ParsedLine("", nil, tags, false, nil, "Unclosed quoted comment") }
        var source = text.string.netTrim
        if source.startsWithIgnoreCase("forget ") {
            let name = source.netSubstring(7).netTrim
            if !FunctionLibrary.validIdentifier(name, 64) || FunctionLibrary.isBuiltin(name) { return ParsedLine(source, nil, [], false, nil, "Invalid function name") }
            return ParsedLine(source, nil, [], false, nil, nil).with { $0.directive = FunctionDirective(key: sha256Hex("FORGET " + name.netUpper), definition: nil, name: name); $0.functionName = name }
        }
        let equal = TextSyntax.assignmentIndex(source); var assignment: String?
        // "solve left = right" is an equation, not an assignment or definition; Parse re-checks for a user variable named solve.
        if equal >= 0 && EquationSyntax.prefix(source) { return ParsedLine(source, nil, distinctIgnoringCase(tags), false, nil, nil) }
        if equal >= 0 && source.netSubstring(0, equal).contains("(") {
            let open = source.netIndexOf("("); let name = source.netSubstring(0, open).netTrim
            do {
                let header = source.netSubstring(0, equal).netTrim
                if !FunctionLibrary.validIdentifier(name, 64) || !header.hasSuffix(")") { throw CalcError.format("Invalid function signature") }
                let parameterText = header.netSlice(open + 1, header.netLength - 1)
                let parameters = parameterText.netTrim.isEmpty ? [] : parameterText.netSplit(",").map { $0.netTrim }
                let definition = FunctionDefinition(name: name, parameters: parameters, body: source.netSubstring(equal + 1).netTrim)
                let key = sha256Hex(try FunctionLibrary.canonical(definition))
                return ParsedLine(source, nil, [], false, nil, nil).with { $0.directive = FunctionDirective(key: key, definition: definition, name: name); $0.functionName = name }
            } catch let e as CalcError where e.isFormatOrArithmetic { return ParsedLine(source, nil, [], false, nil, e.message).with { $0.functionName = name } }
        }
        if equal >= 0 {
            assignment = normalizeName(source.netSubstring(0, equal)); source = source.netSubstring(equal + 1).netTrim
            if !validName(assignment!) { return ParsedLine(source, nil, tags, false, nil, "Invalid variable name") }
        }
        return ParsedLine(source, assignment, distinctIgnoringCase(tags), false, nil, nil)
    }
    static func parse(_ line: ParsedLine, _ names: NetHashSet<String>, _ cancellationToken: CancellationToken) throws -> ParsedLine {
        if line.error != nil || line.boundary || line.directive != nil || line.expression != nil { return line }
        do {
            if let dice = try DiceSyntax.tryParse(line.text, names) { return line.with { $0.expression = DiceExpression(dice) } }
            if EquationSyntax.prefix(line.text) && !names.contains("solve") { let parsed = try EquationSyntax.parse(line.text, names, cancellationToken); return line.with { $0.expression = parsed } }
            var tokens = try ExpressionParser.tokenize(line.text, cancellationToken, names)
            if tokens.isEmpty { return line.assignment == nil ? line : line.with { $0.error = "Expected expression" } }
            if let worksheet = try WorksheetSyntax.tryParse(tokens, names, cancellationToken) {
                if line.tags.count > 1 { throw CalcError.format("Use one tag filter per chart") }
                if let chart = worksheet as? ChartExpression, chart.data == nil { return line.with { $0.expression = chart.with(tag: line.tags.first) } }
                return line.with { $0.expression = worksheet }
            }
            let sumLength = KeywordCatalog.match(tokens, 0, .sum)
            let averageLength = KeywordCatalog.match(tokens, 0, .average)
            let aggregateLength = max(sumLength, averageLength)
            let aggregateName = tokens.prefix(aggregateLength).map(\.text).joined(separator: " ")
            if aggregateLength > 0 && !names.contains(aggregateName) &&
                (tokens.count == aggregateLength || tokens[aggregateLength].text.equalsIgnoreCase("in") || KeywordCatalog.match(tokens, aggregateLength, .to) > 0 ||
                 KeywordCatalog.match(tokens, aggregateLength, .leadingDecimals) > 0 || KeywordCatalog.match(tokens, aggregateLength, .leadingSignificant) > 0) {
                if line.tags.count > 1 { throw CalcError.format("Use one tag filter per aggregate") }
                let aggregate = AggregateExpression(averageLength > 0, line.tags.first)
                let parsed = try ExpressionParser(tokens, cancellationToken, names).parseAggregate(aggregate, aggregateLength)
                return line.with { $0.expression = parsed }
            }
            // Only a leading label directly followed by a number can be ignored. Known operands
            // and unknown words next to arithmetic operators are never silently discarded.
            var count = 0
            while count < tokens.count && tokens[count].kind == .name { count += 1 }
            var knownPrefix = ConstantCatalog.isRoundingLine(tokens)
            var prefix = ""
            for n in 0..<count {
                if n > 0 { prefix += " " }
                prefix += tokens[n].text
                if prefix.netLength > 128 { break }
                if names.contains(prefix) || isReserved(prefix) { knownPrefix = true; break }
            }
            let prefixLength = max(KeywordCatalog.match(tokens, 0, .double), KeywordCatalog.match(tokens, 0, .half))
            let conversational = !knownPrefix && prefixLength > 0 && tokens.count > prefixLength && tokens[prefixLength].text != "("
            let datePhrase = try DateSyntax.isNaturalStart(tokens, names) || tokens[tokens.count - 1].text.equalsIgnoreCase("ago")
            let startsDate = try DateSyntax.tryLiteral(tokens, 0) != nil
            let salaryPhrase = tokens.dropFirst().contains { ["gross", "brut", "brutto", "net"].contains($0.text.netLower) }
            let timePhrase = salaryPhrase || ["uuid", "from", "now", "unix", "loan", "mortgage", "amortize", "save", "fire", "depreciate", "break", "late"].contains(tokens[0].text.netLower)
            var moneyPhrase = tokens[0].kind == .currency
            if !moneyPhrase && line.assignment == nil && !knownPrefix, let (_, currencyPrefix) = try CurrencyCatalog.tryMatch(tokens, 0), currencyPrefix < tokens.count {
                moneyPhrase = tokens[currencyPrefix].kind == .number || tokens[currencyPrefix].kind == .integer || ["(", "+", "-"].contains(tokens[currencyPrefix].text)
            }
            var practicalPhrase = false
            if !knownPrefix {
                practicalPhrase = try ExpressionParser(tokens, cancellationToken, names).startsHelper() || tokens[0].text.equalsIgnoreCase("grades") ||
                    tokens.count > 1 && tokens[0].text.equalsIgnoreCase("molar") && tokens[1].text.equalsIgnoreCase("mass")
            }
            let resistorPhrase = !knownPrefix && count >= 3 && tokens.prefix(3).allSatisfy { ResistorColorCatalog.tryGet($0.text) != nil }
            if line.assignment == nil && tokens.allSatisfy({ $0.kind == .name }) && !names.contains(normalizeName(line.text)) &&
                !(tokens.count == 1 && (["pi", "π"].contains(tokens[0].text.netLower) || ConstantCatalog.isLoneValue(tokens[0].text))) {
                if try !ConstantCatalog.isConversionLine(tokens) && !isReserved(normalizeName(line.text)) && !conversational && !datePhrase && !timePhrase && !resistorPhrase && !practicalPhrase {
                    var knownTail = false
                    if knownPrefix {
                        for index in 0..<tokens.count {
                            let lower = tokens[index].text.netLower
                            if try ["at", "for", "uptime"].contains(lower) || tokens[index].text.equalsIgnoreCase("in") || tokens[index].text.equalsIgnoreCase("net") ||
                                CurrencyCatalog.tryMatch(tokens, index) != nil || KeywordCatalog.match(tokens, index, .to) > 0 ||
                                KeywordCatalog.match(tokens, index, .leadingDecimals) > 0 || KeywordCatalog.match(tokens, index, .leadingSignificant) > 0 { knownTail = true; break }
                        }
                    }
                    if !knownTail { return line }
                }
            }
            if line.assignment == nil && count > 0 && count < tokens.count && [.ip, .integer, .number, .date, .time].contains(tokens[count].kind) &&
                !knownPrefix && !conversational && !datePhrase && !startsDate && !timePhrase && !moneyPhrase && !resistorPhrase && !practicalPhrase {
                if (0..<count).contains(where: { KeywordCatalog.match(tokens, $0, .double) > 0 || KeywordCatalog.match(tokens, $0, .half) > 0 }) {
                    throw CalcError.format("Quote labels before conversational expressions")
                }
                let drop = try count > 1 && DateSyntax.tryLiteral(tokens, count - 1) != nil ? count - 1 : count
                tokens = Array(tokens.dropFirst(drop))
            }
            let parsed = try ExpressionParser(tokens, cancellationToken, names).parse()
            return line.with { $0.expression = parsed }
        } catch let e as CalcError where e.isFormatOrArithmetic { return line.with { $0.error = e.message } }
    }
}
