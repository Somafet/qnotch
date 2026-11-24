import Foundation

enum HelperKind { case bmr, tdee, heartZones, pace, runTime, race, paint, tiles, concrete, fuelTrip, timeDifference, scale, ingredient, count }
/// One practical-helper sentence. Operands are evaluated first, in order; `words` name the grammar options that were written.
final class HelperExpression: Expression {
    let kind: HelperKind, operands: [Expression], words: [String], unit: UnitExpression?
    init(_ kind: HelperKind, _ operands: [Expression], _ words: [String], _ unit: UnitExpression? = nil) { self.kind = kind; self.operands = operands; self.words = words; self.unit = unit }
    var children: [Expression] { operands }
}

private let helperHeads: NetHashSet<String> = {
    var heads = NetHashSet<String>.ignoringCase()
    for head in ["bmr", "tdee", "hr", "pace", "race", "paint", "tiles", "concrete", "time", "scale"] { heads.insert(head) }
    return heads
}()
private let timePerLength = Dimension(-1, 0, 1, 0, 0, 0, 0, 0)

extension ExpressionParser {
    /// C# StartsHelper: TryHelper succeeds and consumes every token; format and arithmetic errors mean no, cancellation and limits propagate.
    func startsHelper() throws -> Bool {
        do { return try tryHelper() != nil && position == tokens.count } catch let error as CalcError where error.isFormatOrArithmetic { return false }
    }
    /// A helper sentence applies only when its complete grammar matches; otherwise the words keep their ordinary meaning as labels, prose or names.
    func tryHelper() throws -> Expression? {
        if position >= tokens.count { return nil }
        let head = current.kind == .name && helperHeads.contains(current.text) && knownNameLength(position) == 0
        if !head && !hasAtWord { return nil }
        var end = position, nesting = 0
        while end < tokens.count {
            let text = tokens[end].text
            if nesting == 0 && (text == ")" || text == "," || text == "]") { break }
            if text == "(" { nesting += 1 } else if text == ")" { nesting -= 1 }
            end += 1
        }
        if end == position { return nil }
        let segment = sub(position, end - position)
        var sentence: Expression?
        do {
            sentence = head ? try segment.headSentence() : try segment.atSentence()
            if let found = sentence { sentence = try segment.roundingTail(found) }
        } catch let error as CalcError where error.isFormatOrArithmetic { return nil }
        guard let sentence, segment.current.kind == .end else { return nil }
        position = end; return sentence
    }
    private func word(_ word: String) -> Bool {
        if current.kind != .name || !current.text.equalsIgnoreCase(word) { return false }
        position += 1; return true
    }
    private func slice(_ start: Int, _ end: Int) throws -> Expression { try sub(start, end - start).parse() }
    private func topLevel(_ start: Int, _ match: (Int) -> Bool) -> Int {
        var nesting = 0, index = start
        while index < tokens.count {
            if tokens[index].text == "(" { nesting += 1 } else if tokens[index].text == ")" { nesting -= 1 }
            else if nesting == 0 && match(index) { return index }
            index += 1
        }
        return -1
    }
    private func headSentence() throws -> Expression? {
        let head = current.text.netLower; position += 1
        switch head {
        case "bmr": return try bodySentence(.bmr)
        case "tdee": return try bodySentence(.tdee)
        case "hr": return try heartZonesSentence()
        case "pace": return try paceSentence()
        case "race": return try raceSentence()
        case "paint": return try paintSentence()
        case "tiles": return try tilesSentence()
        case "concrete": return try concreteSentence()
        case "time": return try timeDifferenceSentence()
        case "scale": return try scaleSentence()
        default: return nil
        }
    }
    /// An existing variable or parameter, read as the operand it names.
    private func namedOperand() -> Expression? {
        let length = current.kind == .name ? knownNameLength(position) : 0
        if length == 0 { return nil }
        let name = tokens[position..<(position + length)].map(\.text).joined(separator: " "); position += length
        return NameExpression(name)
    }
    /// A literal count, a variable or a parenthesized expression.
    private func countOperand() throws -> Expression? {
        if current.kind == .number { return try number() }
        if let named = namedOperand() { return named }
        if current.text != "(" { return nil }
        let start = position; position += 1; let inner = try rounded()
        if take(")") { return inner }
        position = start; return nil
    }
    /// A number with a unit (adjacent parts of one dimension add, as in 5 ft 11 in) or a parenthesized expression.
    private func quantityOperand() throws -> Expression? {
        if current.kind == .name { return try countOperand() }
        if current.text == "(" {
            let group = try countOperand() // a unit may follow the group: (20 + 7) min; "in" starts a conversion, not inches
            if let group, current.kind == .name, !current.text.equalsIgnoreCase("in"), let groupUnit = try UnitParser.tryParse(tokens, &position, knownNames) {
                return UnitExpressionNode(group, groupUnit, false)
            }
            return group
        }
        if current.kind != .number { return nil }
        let start = position; let amount = try number()
        guard let unit = try UnitParser.tryParse(tokens, &position, knownNames) else { position = start; return nil }
        var quantity: Expression = UnitExpressionNode(amount, unit, false)
        while current.kind == .number {
            let part = position; let next = try number()
            guard let more = try UnitParser.tryParse(tokens, &position, knownNames), more.dimension == unit.dimension else { position = part; break }
            quantity = BinaryExpression("+", quantity, UnitExpressionNode(next, more, false))
        }
        return quantity
    }
    private func ageWord() -> Bool { word("years") || word("year") || word("yrs") || word("yr") }
    private func ageOperand() throws -> Expression? {
        let age = try countOperand()
        if age != nil { _ = ageWord() }
        return age
    }
    private static var secondsUnit: UnitExpression { get throws { try .single(UnitCatalog.byId("s")) } }
    /// m:ss or h:mm:ss. The tokenizer reads these as clock literals; here they are durations.
    private func clockDuration() throws -> Expression? {
        if current.kind != .time { return nil }
        let parts = current.text.netSplit(":")
        if parts.count < 2 || parts.count > 3 || parts.contains(where: { $0.isEmpty || $0.utf16.first == 0x2E }) { return nil }
        let last = parts[parts.count - 1].netSplit(".")
        func digits(_ text: String) -> Bool { text.utf16.allSatisfy(NetChar.isAsciiDigit) }
        if last.count > 2 || last[0].netLength != 2 || !parts.dropLast().allSatisfy(digits) || !last.allSatisfy(digits) { return nil }
        let seconds = try Rational.parse(parts[parts.count - 1])
        let minutes = parts.count == 3 ? try Rational.parse(parts[1]) : try Rational.parse(parts[0])
        let hours = parts.count == 3 ? try Rational.parse(parts[0]) : Rational.zero
        if seconds.numerator >= 60 * seconds.denominator || parts.count == 3 && (parts[1].netLength != 2 || minutes.numerator >= 60) { return nil }
        position += 1
        return UnitExpressionNode(LiteralExpression(try hours * Rational(3600) + minutes * Rational(60) + seconds), try ExpressionParser.secondsUnit, false)
    }
    private func durationOperand() throws -> Expression? { current.kind == .time ? try clockDuration() : try quantityOperand() }
    private func bodySentence(_ kind: HelperKind) throws -> Expression? {
        let mass = try quantityOperand(); let height = mass == nil ? nil : try quantityOperand(); let age = height == nil ? nil : try ageOperand()
        guard let mass, let height, let age, current.kind == .name, ["male", "female"].contains(current.text.netLower) else { return nil }
        let sex = current.text.netLower; position += 1
        if kind == .bmr { return HelperExpression(kind, [mass, height, age], [sex]) }
        var level = current.kind == .name ? current.text.netLower : ""
        if level == "very" && position + 1 < tokens.count && tokens[position + 1].text.equalsIgnoreCase("active") { position += 2; level = "very active" }
        else if ["sedentary", "light", "moderate", "active"].contains(level) { position += 1 }
        else { return nil }
        return HelperExpression(kind, [mass, height, age], [sex, level])
    }
    private func heartZonesSentence() throws -> Expression? {
        if !word("zones") && !word("zone") { return nil }
        let mode = word("age") ? "age" : word("max") ? "max" : ""
        if mode.isEmpty { return nil }
        guard let value = try countOperand() else { return nil }
        if mode == "age" { _ = ageWord() } else { _ = word("bpm") }
        return HelperExpression(.heartZones, [value], [mode])
    }
    private func paceSentence() throws -> Expression? {
        guard let distance = try quantityOperand() else { return nil }
        _ = take("in")
        guard let time = try durationOperand() else { return nil }
        return HelperExpression(.pace, [distance, time], [])
    }
    private static func kilometres(_ amount: Expression) throws -> Expression { UnitExpressionNode(amount, try .single(UnitCatalog.byId("km")), false) }
    private func raceSentence() throws -> Expression? {
        guard let distance = try quantityOperand() else { return nil }
        _ = take("in")
        guard let time = try durationOperand(), take("to") || takeKeyword(.to), knownNameLength(position) == 0 else { return nil }
        let target: Expression?
        if word("marathon") { target = try ExpressionParser.kilometres(LiteralExpression(try Rational(42195, 1000))) }
        else if current.text.equalsIgnoreCase("half") && (position + 1 < tokens.count && tokens[position + 1].text.equalsIgnoreCase("marathon") ||
                    position + 2 < tokens.count && tokens[position + 1].text == "-" && tokens[position + 2].text.equalsIgnoreCase("marathon")) {
            position += tokens[position + 1].text == "-" ? 3 : 2; target = try ExpressionParser.kilometres(LiteralExpression(try Rational(210975, 10000)))
        } else if current.kind == .number && position + 1 < tokens.count && tokens[position + 1].kind == .name && tokens[position + 1].joinedToPrevious &&
                    tokens[position + 1].text.equalsIgnoreCase("k") {
            target = try ExpressionParser.kilometres(LiteralExpression(try Rational.parse(current.text))); position += 2
        } else { target = try quantityOperand() }
        guard let target else { return nil }
        return HelperExpression(.race, [distance, time, target], [])
    }
    private func percentOperand() throws -> Expression? {
        guard let value = try countOperand() else { return nil }
        if take("%") || word("percent") { return UnaryExpression("%", value) }
        return value is NameExpression ? value : nil
    }
    private func paintSentence() throws -> Expression? {
        guard let area = try quantityOperand() else { return nil }
        var operands: [Expression] = [area], words: [String] = []
        if current.kind == .number || current.text == "(" || knownNameLength(position) > 0 {
            guard let coats = try countOperand(), word("coats") || word("coat") else { return nil }
            operands.append(coats); words.append("coats")
        }
        if word("at") { guard let rate = try quantityOperand() else { return nil }; operands.append(rate); words.append("rate") }
        return HelperExpression(.paint, operands, words)
    }
    private func tilesSentence() throws -> Expression? {
        guard let area = try quantityOperand() else { return nil }
        _ = word("with") || word("plus")
        if current.kind != .number && current.text != "(" && knownNameLength(position) == 0 && !current.text.equalsIgnoreCase("waste") { return HelperExpression(.tiles, [area], []) }
        let waste: Expression?
        if word("waste") { waste = try percentOperand() }
        else { waste = try percentOperand(); if waste == nil || !word("waste") { return nil } }
        guard let waste else { return nil }
        return HelperExpression(.tiles, [area, waste], ["waste"])
    }
    private func concreteSentence() throws -> Expression? {
        guard let volume = try quantityOperand() else { return nil }
        var operands: [Expression] = [volume], words: [String] = []
        if current.kind == .number || current.text == "(" || knownNameLength(position) > 0 {
            guard let bag = try quantityOperand(), word("bags") || word("bag") else { return nil }
            operands.append(bag); words.append("bag")
        }
        if word("at") { guard let density = try quantityOperand() else { return nil }; operands.append(density); words.append("density") }
        return HelperExpression(.concrete, operands, words)
    }
    private func timeDifferenceSentence() throws -> Expression? {
        if !word("difference") { return nil }
        _ = word("from")
        if knownNameLength(position) > 0 { return nil }
        guard let first = try tryZone(explicitTarget: true), take("to") || takeKeyword(.to), knownNameLength(position) == 0,
              let second = try tryZone(explicitTarget: true) else { return nil }
        if word("on") {
            guard let (date, length) = try DateSyntax.tryLiteral(tokens, position) else { return nil }
            position += length; return HelperExpression(.timeDifference, [DateLiteralExpression(date)], [first, second])
        }
        return HelperExpression(.timeDifference, [], [first, second])
    }
    private func scaleSentence() throws -> Expression? {
        let from = topLevel(position) { self.tokens[$0].kind == .name && self.tokens[$0].text.equalsIgnoreCase("from") }
        let to = from < 0 ? -1 : topLevel(from + 1) { KeywordCatalog.match(self.tokens, $0, .to) > 0 }
        if from <= position || to <= from + 1 { return nil }
        var last = tokens.count; let tail = tokens[tokens.count - 1].text.netLower
        if ["servings", "serving", "portions", "portion", "people"].contains(tail) { last -= 1 }
        if last <= to + 1 { return nil }
        let result = HelperExpression(.scale, [try slice(position, from), try slice(from + 1, to), try slice(to + 1, last)], [])
        position = tokens.count; return result
    }
    /// `5:30/km` or `5:30 per mi`: time per distance.
    private func paceLiteral() throws -> Expression? {
        guard let clock = try clockDuration(), take("/") || word("per"), let unit = try UnitParser.tryParse(tokens, &position, knownNames),
              unit.dimension == Dimension(1, 0, 0, 0, 0, 0, 0, 0) else { return nil }
        return BinaryExpression("/", clock, UnitExpressionNode(LiteralExpression(Rational.one), unit, false))
    }
    /// `distance at pace` or `distance at consumption [at price]`; the right side must visibly be a pace or a fuel unit.
    private func atSentence() throws -> Expression? {
        let at = topLevel(position) { self.tokens[$0].kind == .name && self.tokens[$0].text.equalsIgnoreCase("at") }
        if at <= position || at + 1 >= tokens.count { return nil }
        let right = ExpressionParser(Array(tokens[(at + 1)...]), cancellationToken, knownNames, questionDepth + 1)
        let rate = right.current.kind == .time ? try right.paceLiteral() : try right.quantityOperand()
        var pace = false, fuel = false
        if let binary = rate as? BinaryExpression, binary.operation == "/", binary.right is UnitExpressionNode { pace = true }
        if let quantity = rate as? UnitExpressionNode, !quantity.conversion {
            if quantity.unit.dimension == timePerLength { pace = true }
            if quantity.unit.fuelForm() != 0 { fuel = true }
        }
        guard let rate, pace || fuel else { return nil }
        let distance = try slice(position, at)
        position = at + 1 + right.position
        if pace { return HelperExpression(.runTime, [distance, rate], []) }
        if !word("at") { return HelperExpression(.fuelTrip, [distance, rate], []) }
        let price = try slice(position, tokens.count); position = tokens.count
        return HelperExpression(.fuelTrip, [distance, rate, price], ["price"])
    }
    /// `1 cup flour in g`: an ingredient name between a measured quantity and its conversion target.
    func tryIngredientSuffix(_ expression: inout Expression) throws -> Bool {
        if expression is LiteralExpression || current.kind != .name { return false }
        let start = position; _ = takeKeyword(.of)
        if position >= tokens.count || knownNameLength(position) > 0 { position = start; return false }
        func connective(_ index: Int) -> Int {
            tokens[index].kind == .name && tokens[index].text.equalsIgnoreCase("in") ? 1 : KeywordCatalog.match(tokens, index, .to)
        }
        let match = IngredientCatalog.tryMatch(tokens, position)
        var end = position + (match?.length ?? 0)
        if match == nil { while end < tokens.count && end - position < 4 && tokens[end].kind == .name && connective(end) == 0 { end += 1 } }
        if end == position || end >= tokens.count { position = start; return false }
        let width = connective(end)
        if width == 0 { position = start; return false }
        var cursor = end + width
        guard let target = try UnitParser.tryParse(tokens, &cursor, knownNames) else { position = start; return false }
        if let ingredient = match?.definition { position = cursor; expression = HelperExpression(.ingredient, [expression], [ingredient.id], target); return true }
        // An unknown name is an error only when the sentence is otherwise a volume (or mass) quantity converted to the opposite dimension.
        let mass = Dimension(0, 1, 0, 0, 0, 0, 0, 0), volume = Dimension(3, 0, 0, 0, 0, 0, 0, 0)
        if let measured = expression as? UnitExpressionNode, !measured.conversion,
           measured.unit.dimension == volume && target.dimension == mass || measured.unit.dimension == mass && target.dimension == volume {
            throw CalcError.format("Unknown ingredient: " + tokens[position..<end].map(\.text).joined(separator: " "))
        }
        position = start; return false
    }
    /// `3 sets`, `8 reps`: dimensionless counts, read only directly after a literal number and never over a user name.
    func tryCountSuffix(_ expression: inout Expression) throws -> Bool {
        if !(expression is LiteralExpression) || current.kind != .name || !["set", "sets", "rep", "reps"].contains(current.text.netLower) ||
            knownNameLength(position) > 0 || position + 1 < tokens.count && tokens[position + 1].text == "(" { return false }
        expression = HelperExpression(.count, [expression], [current.text.netLower]); position += 1; return true
    }
}
