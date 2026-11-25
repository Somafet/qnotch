import Foundation

// Expression nodes. C# uses records matched by type; here each node is a final class conforming to
// `Expression`, and lists its operands (in evaluation order) through `children` (C# ExpressionEvaluation.Children).

protocol Expression: AnyObject {
    /// The operand nodes, evaluated left to right before this node.
    var children: [Expression] { get }
}
extension Expression { var children: [Expression] { [] } }

final class LiteralExpression: Expression { let value: Rational; init(_ value: Rational) { self.value = value } }
final class NameExpression: Expression { let name: String; init(_ name: String) { self.name = name } }
final class UnaryExpression: Expression {
    let operation: String, operand: Expression
    init(_ operation: String, _ operand: Expression) { self.operation = operation; self.operand = operand }
    var children: [Expression] { [operand] }
}
final class BinaryExpression: Expression {
    let operation: String, left: Expression, right: Expression
    init(_ operation: String, _ left: Expression, _ right: Expression) { self.operation = operation; self.left = left; self.right = right }
    var children: [Expression] { [left, right] }
}
final class CallExpression: Expression {
    let name: String, arguments: [Expression]
    var site = 0
    init(_ name: String, _ arguments: [Expression], site: Int = 0) { self.name = name; self.arguments = arguments; self.site = site }
    var children: [Expression] { arguments }
}
final class AggregateExpression: Expression {
    let average: Bool, tag: String?
    init(_ average: Bool, _ tag: String?) { self.average = average; self.tag = tag }
}
final class RoundingExpression: Expression {
    let kind: RoundingKind, operand: Expression, precision: Expression
    init(_ kind: RoundingKind, _ operand: Expression, _ precision: Expression) { self.kind = kind; self.operand = operand; self.precision = precision }
    var children: [Expression] { [operand, precision] }
}
final class ScaleExpression: Expression {
    let modifier: String, factor: Rational, operand: Expression
    init(_ modifier: String, _ factor: Rational, _ operand: Expression) { self.modifier = modifier; self.factor = factor; self.operand = operand }
    var children: [Expression] { [operand] }
}
final class UnitExpressionNode: Expression {
    let operand: Expression, unit: UnitExpression, conversion: Bool
    init(_ operand: Expression, _ unit: UnitExpression, _ conversion: Bool) { self.operand = operand; self.unit = unit; self.conversion = conversion }
    var children: [Expression] { [operand] }
}
final class DateLiteralExpression: Expression { let date: DateOnly; init(_ date: DateOnly) { self.date = date } }
final class DateAnchorExpression: Expression {
    let offset: Int, weekday: DayOfWeek?, direction: Int
    init(offset: Int = 0, weekday: DayOfWeek? = nil, direction: Int = 1) { self.offset = offset; self.weekday = weekday; self.direction = direction }
}
final class CalendarPeriodExpression: Expression {
    let count: Expression, monthsPerUnit: Int
    init(_ count: Expression, _ monthsPerUnit: Int) { self.count = count; self.monthsPerUnit = monthsPerUnit }
    var children: [Expression] { [count] }
}
final class DateIntervalExpression: Expression {
    let kind: String, from: Expression, to: Expression
    init(_ kind: String, _ from: Expression, _ to: Expression) { self.kind = kind; self.from = from; self.to = to }
    var children: [Expression] { [from, to] }
}
final class DateShiftExpression: Expression {
    let date: Expression, offset: Expression, direction: Int
    init(_ date: Expression, _ offset: Expression, _ direction: Int) { self.date = date; self.offset = offset; self.direction = direction }
    var children: [Expression] { [date, offset] }
}
final class TimeLiteralExpression: Expression { let time: ClockTime; init(_ time: ClockTime) { self.time = time } }
final class TimeRangeExpression: Expression {
    let start: Expression, end: Expression
    init(_ start: Expression, _ end: Expression) { self.start = start; self.end = end }
    var children: [Expression] { [start, end] }
}
final class ListExpression: Expression { let items: [Expression]; init(_ items: [Expression]) { self.items = items }; var children: [Expression] { items } }
final class AnnualHolidayExpression: Expression { let month: Int, day: Int; init(_ month: Int, _ day: Int) { self.month = month; self.day = day } }
final class WorkdayPeriodExpression: Expression { let count: Expression; init(_ count: Expression) { self.count = count }; var children: [Expression] { [count] } }
final class WorkdayCountExpression: Expression {
    let from: Expression, to: Expression
    init(_ from: Expression, _ to: Expression) { self.from = from; self.to = to }
    var children: [Expression] { [from, to] }
}
final class CalendarEventExpression: Expression {
    let month: Int, day: Int, weekday: DayOfWeek?
    init(month: Int = 0, day: Int = 0, weekday: DayOfWeek? = nil) { self.month = month; self.day = day; self.weekday = weekday }
}
final class CountdownExpression: Expression { let deadline: Expression; init(_ deadline: Expression) { self.deadline = deadline }; var children: [Expression] { [deadline] } }
final class CountdownZoneExpression: Expression {
    let deadline: Expression, zone: String, ambiguity: String
    init(_ deadline: Expression, _ zone: String, _ ambiguity: String) { self.deadline = deadline; self.zone = zone; self.ambiguity = ambiguity }
    var children: [Expression] { [deadline] }
}
final class TimestampJoinExpression: Expression {
    let date: Expression, time: Expression
    init(_ date: Expression, _ time: Expression) { self.date = date; self.time = time }
    var children: [Expression] { [date, time] }
}
final class ZoneExpression: Expression {
    let operand: Expression, zone: String, conversion: Bool, ambiguity: String
    init(_ operand: Expression, _ zone: String, _ conversion: Bool, _ ambiguity: String = "") { self.operand = operand; self.zone = zone; self.conversion = conversion; self.ambiguity = ambiguity }
    var children: [Expression] { [operand] }
}
final class UnixExpression: Expression {
    let operand: Expression, export: Bool
    init(_ operand: Expression, _ export: Bool) { self.operand = operand; self.export = export }
    var children: [Expression] { [operand] }
}
final class NowExpression: Expression {}
final class UnitOrZoneExpression: Expression {
    let operand: Expression, zone: String, unit: UnitExpression, conversion: Bool
    init(_ operand: Expression, _ zone: String, _ unit: UnitExpression, _ conversion: Bool) { self.operand = operand; self.zone = zone; self.unit = unit; self.conversion = conversion }
    var children: [Expression] { [operand] }
}
final class CurrencyAttachExpression: Expression {
    let operand: Expression, currency: String
    init(_ operand: Expression, _ currency: String) { self.operand = operand; self.currency = currency }
    var children: [Expression] { [operand] }
}
final class CurrencyConvertExpression: Expression {
    let operand: Expression, currency: String, unit: UnitExpression?, date: Expression?
    init(_ operand: Expression, _ currency: String, unit: UnitExpression? = nil, date: Expression? = nil) { self.operand = operand; self.currency = currency; self.unit = unit; self.date = date }
    var children: [Expression] { date == nil ? [operand] : [date!, operand] }
}
final class ImaginaryExpression: Expression { let coefficient: Rational; init(_ coefficient: Rational) { self.coefficient = coefficient } }
final class IntegerLiteralExpression: Expression { let text: String; init(_ text: String) { self.text = text } }
final class IntegerConvertExpression: Expression {
    let operand: Expression, radix: Int?, width: Int?, signed: Bool
    init(_ operand: Expression, _ radix: Int?, _ width: Int?, _ signed: Bool) { self.operand = operand; self.radix = radix; self.width = width; self.signed = signed }
    var children: [Expression] { [operand] }
}
final class IpLiteralExpression: Expression { let text: String; init(_ text: String) { self.text = text } }
final class NetworkMembershipExpression: Expression {
    let address: Expression, subnet: Expression
    init(_ address: Expression, _ subnet: Expression) { self.address = address; self.subnet = subnet }
    var children: [Expression] { [address, subnet] }
}
final class PrefixMaskExpression: Expression { let prefix: Int, family: Int; init(_ prefix: Int, _ family: Int) { self.prefix = prefix; self.family = family } }
final class UuidExpression: Expression { let site: Int; init(_ site: Int) { self.site = site } }
final class ConstantExpression: Expression {
    let name: String, magnitude: Bool
    init(_ name: String, magnitude: Bool = false) { self.name = name; self.magnitude = magnitude }
}
final class EngineeringExpression: Expression { let operand: Expression; init(_ operand: Expression) { self.operand = operand }; var children: [Expression] { [operand] } }

enum TokenKind { case colour, codepoint, aspect, text, ip, integer, number, name, symbol, date, time, zone, currency, end }
struct Token: Hashable {
    let kind: TokenKind, text: String, joinedToPrevious: Bool
    init(_ kind: TokenKind, _ text: String, _ joinedToPrevious: Bool = false) { self.kind = kind; self.text = text; self.joinedToPrevious = joinedToPrevious }
}

final class ExpressionParser {
    let tokens: [Token]
    let cancellationToken: CancellationToken
    let knownNames: NetHashSet<String>?
    let questionDepth: Int
    var position = 0
    var depth = 0
    let hasDatePhrases: Bool
    let hasPlanningPhrases: Bool
    let hasInvoicePhrases: Bool
    let hasSalaryPhrases: Bool
    let hasRatePhrases: Bool
    let hasAtWord: Bool

    init(_ tokens: [Token], _ cancellationToken: CancellationToken, _ knownNames: NetHashSet<String>? = nil, _ questionDepth: Int = 0) {
        self.tokens = tokens; self.cancellationToken = cancellationToken; self.knownNames = knownNames; self.questionDepth = questionDepth
        let lower = tokens.map { $0.text.netLower }
        hasDatePhrases = zip(tokens, lower).contains { $0.kind == .name && ["in", "ago", "days", "weeks", "age", "workday", "workdays", "working", "business"].contains($1) }
        hasPlanningPhrases = lower.contains { ["fire", "depreciate", "break", "inflation"].contains($0) }
        hasInvoicePhrases = lower.contains { $0 == "net" || $0 == "late" }
        hasSalaryPhrases = lower.contains { ["gross", "brut", "brutto", "net"].contains($0) }
        hasRatePhrases = zip(tokens, lower).contains { $0.kind == .name && ($1 == "for" || $1 == "uptime") }
        hasAtWord = tokens.contains { $0.kind == .name && $0.text.equalsIgnoreCase("at") }
    }
    var current: Token { position < tokens.count ? tokens[position] : Token(.end, "") }
    /// A parser over part of these tokens (C# `new ExpressionParser(tokens.Skip(start).Take(count)…)`).
    func sub(_ start: Int, _ count: Int, depth: Int? = nil) -> ExpressionParser {
        let s = min(max(start, 0), tokens.count), e = min(s + max(count, 0), tokens.count)
        return ExpressionParser(Array(tokens[s..<e]), cancellationToken, knownNames, depth ?? questionDepth + 1)
    }
    func part(_ start: Int, _ count: Int) throws -> Expression { try sub(start, count).parse() }

    func parse() throws -> Expression {
        if questionDepth > 16 { throw CalcError.arithmetic("Question depth limit exceeded") }
        if let helper = try tryHelper() { return helper }
        if let grades = try tryGrades() { if current.kind != .end { throw CalcError.format("Unexpected text after grades") }; return grades }
        if let salary = try trySalarySentence() { return salary }
        if let invoice = try tryInvoiceSentence() { return invoice }
        if let planning = try tryPlanningSentence() { return planning }
        if let financial = try tryFinancialSentence() { return financial }
        if let workdays = try tryWorkdaySentence() { return workdays }
        if let date = try tryDateSentence() { return date }
        if let rate = try tryRateForSentence() { return rate }
        let isIndex = tokens.firstIndex { $0.kind == .name && $0.text.equalsIgnoreCase("is") } ?? -1
        if isIndex > 0 {
            let tail = Array(tokens[(isIndex + 1)...])
            if tail.count >= 4 && tail[0].text.equalsIgnoreCase("what") && tail[1].text == "%" && tail[2].text.equalsIgnoreCase("of") {
                return CallExpression("share", [try sub(0, isIndex).parse(), try sub(isIndex + 4, tokens.count - isIndex - 4).parse()])
            }
            if tail.count >= 4 && tail[tail.count - 1].text.equalsIgnoreCase("what") {
                let operation = tail[tail.count - 2].text.netLower
                if operation == "of" || operation == "off" {
                    return CallExpression(operation == "of" ? "whole" : "beforeDiscount", [try sub(0, isIndex).parse(), try sub(isIndex + 1, tokens.count - isIndex - 3).parse()])
                }
            }
        }
        let expression = try rounded()
        if current.kind != .end { throw CalcError.format("Unexpected text") }
        return expression
    }
    func parseAggregate(_ aggregate: AggregateExpression, _ prefixLength: Int = 1) throws -> Expression {
        position = prefixLength
        let expression = try roundingTail(aggregate)
        if current.kind != .end { throw CalcError.format("Unexpected text") }
        return expression
    }
    func rounded() throws -> Expression {
        if let helper = try tryHelper() { return helper }
        if startsCountdown() { return try parseCountdown() }
        if !hasDatePhrases && !hasPlanningPhrases && !hasInvoicePhrases && !hasSalaryPhrases && !hasRatePhrases && !tokens.contains(where: { $0.text.equalsIgnoreCase("at") }) {
            return try roundingTail(bitOr())
        }
        var end = position, nesting = 0
        while end < tokens.count {
            let text = tokens[end].text
            if nesting == 0 && (text == ")" || text == "," || text == "]") { break }
            if text == "(" { nesting += 1 } else if text == ")" { nesting -= 1 }
            end += 1
        }
        if end > position {
            let segment = sub(position, end - position, depth: questionDepth)
            if let phrase = try segment.trySalarySentence() ?? segment.tryInvoiceSentence() ?? segment.tryPlanningSentence() ?? segment.tryFinancialSentence() ??
                segment.tryWorkdaySentence() ?? segment.tryDateSentence() ?? segment.tryRateForSentence() { position = end; return phrase }
        }
        return try roundingTail(bitOr())
    }
    func roundingTail(_ start: Expression) throws -> Expression {
        var expression = start
        while true {
            let conversionPosition = position
            if take("in") || takeKeyword(.to) {
                if try tryUsageConversion(&expression) { continue }
                if try tryNetworkConversion(&expression, tokens[conversionPosition].text.equalsIgnoreCase("in")) { continue }
                let lower = current.text.netLower
                if ["rgb", "hsl", "ratio", "aspect"].contains(lower) {
                    position += 1; expression = CallExpression(lower == "ratio" || lower == "aspect" ? "asratio" : lower, [expression]); continue
                }
                if try tryIntegerConversion(&expression) { continue }
                if lower == "eng" || lower == "engineering" { position += 1; expression = EngineeringExpression(expression); continue }
                if lower == "colors" || lower == "colours" { position += 1; expression = CallExpression("resistorColors", [expression]); continue }
                if let earningsTarget = ExpressionParser.earningsTarget(current.text) { position += 1; expression = EarningsConvertExpression(expression, earningsTarget); continue }
                if try tryCurrencyConversion(&expression) { continue }
                if take("unix") { expression = UnixExpression(expression, true); continue }
                let zoneStart = position
                if let zone = try tryZone(explicitTarget: true) {
                    var unitEnd = zoneStart
                    if let matchingUnit = try UnitParser.tryParse(tokens, &unitEnd, nil), unitEnd == position {
                        expression = UnitOrZoneExpression(expression, zone, matchingUnit, true)
                    } else { expression = ZoneExpression(expression, zone, true) }
                    continue
                }
                if let target = try UnitParser.tryParse(tokens, &position, nil) { expression = UnitExpressionNode(expression, target, true); continue }
                position = conversionPosition
            }
            let to = takeKeyword(.to)
            let leadingDecimal = takeKeyword(.leadingDecimals)
            let leadingSignificant = !leadingDecimal && takeKeyword(.leadingSignificant)
            if !to && !leadingDecimal && !leadingSignificant { return expression }
            if !leadingDecimal && !leadingSignificant && takeKeyword(.nearest) {
                expression = RoundingExpression(.increment, expression, try unary())
            } else {
                let precision = try unary()
                let kind: RoundingKind
                if leadingDecimal || leadingSignificant {
                    if !takeKeyword(.digits) { throw CalcError.format("Expected precision digits") }
                    kind = leadingDecimal ? .decimalPlaces : .significantFigures
                    _ = takeKeyword(.roundEnd)
                } else if takeKeyword(.decimals) { kind = .decimalPlaces }
                else if takeKeyword(.significant) { kind = .significantFigures }
                else { throw CalcError.format("Expected decimals or sig figs") }
                expression = RoundingExpression(kind, expression, precision)
            }
        }
    }
    func takeKeyword(_ role: KeywordRole) -> Bool {
        let length = KeywordCatalog.match(tokens, position, role)
        position += length; return length != 0
    }
    func take(_ text: String) -> Bool {
        if !current.text.equalsIgnoreCase(text) { return false }
        position += 1; return true
    }
    func sum() throws -> Expression {
        var expression = try range()
        while current.text == "+" || current.text == "-" { let op = current.text; position += 1; expression = BinaryExpression(op, expression, try range()) }
        return expression
    }
    func range() throws -> Expression {
        var expression = try parallel()
        while current.text == "–" || current.text.equalsIgnoreCase("to") && position + 1 < tokens.count && tokens[position + 1].kind == .time {
            position += 1; expression = TimeRangeExpression(expression, try parallel())
        }
        return expression
    }
    func parallel() throws -> Expression {
        var expression = try product()
        while take("||") { expression = BinaryExpression("||", expression, try product()) }
        return expression
    }
    func product() throws -> Expression {
        var expression = try unary()
        while true {
            if current.text == "*" || current.text == "/" { let op = current.text; position += 1; expression = BinaryExpression(op, expression, try unary()) }
            else if takeKeyword(.of) { expression = BinaryExpression("of", expression, try unary()) }
            else { return expression }
        }
    }
    func unary(_ allowTimestamp: Bool = true) throws -> Expression {
        try cancellationToken.throwIfCancellationRequested()
        depth += 1
        defer { depth -= 1 }
        if depth > 64 { throw CalcError.arithmetic("Expression depth limit exceeded") }
        if take("+") { return UnaryExpression("+", try unary(allowTimestamp)) }
        if take("-") { return UnaryExpression("-", try unary(allowTimestamp)) }
        if take("~") { return UnaryExpression("~", try unary(allowTimestamp)) }
        let prefixDouble = KeywordCatalog.match(tokens, position, .double)
        let prefixHalf = KeywordCatalog.match(tokens, position, .half)
        let prefixLength = max(prefixDouble, prefixHalf)
        if prefixLength > 0 && knownNameLength(position) == 0 && (position + prefixLength >= tokens.count || tokens[position + prefixLength].text != "(") {
            let modifier = tokens[position..<(position + prefixLength)].map(\.text).joined(separator: " ").netLower; position += prefixLength
            if knownNameLength(position) == 0 { _ = takeKeyword(.of) }
            return ScaleExpression(modifier, prefixHalf > 0 ? try Rational(1, 2) : Rational(2), try unary(allowTimestamp))
        }
        var value = try postfix(allowTimestamp)
        if take("^") { value = BinaryExpression("^", value, try unary(allowTimestamp)) }
        return value
    }
    func postfix(_ allowTimestamp: Bool = true) throws -> Expression {
        var expression = try atom()
        while true {
            // A zone belongs to the complete date-at-clock join. In particular GB
            // is both an IANA zone and a data unit; do not attach it to the clock.
            if !allowTimestamp {
                let zoneStart = position; let isZone = try tryZone() != nil; position = zoneStart
                if isZone { return expression }
            }
            if current.text == "%" || current.text == "!" { let op = current.text; position += 1; expression = UnaryExpression(op, expression) }
            else if try allowTimestamp && tryTimestampTail(&expression) {}
            else if takeKeyword(.postfixHalf) { expression = ScaleExpression("half", try Rational(1, 2), expression) }
            else if takeKeyword(.postfixDouble) { expression = ScaleExpression("double", Rational(2), expression) }
            else if try tryIngredientSuffix(&expression) || tryCountSuffix(&expression) {}
            else if tryWorkdaySuffix(&expression) {}
            else if try tryCurrencySuffix(&expression) {}
            else if try tryUsageSuffix(&expression) {}
            else if tryCalendarEarningsSuffix(&expression) {}
            else if tryCalendarSuffix(&expression) { try compositeTail(&expression) }
            else if try tryChemistrySuffix(&expression) {}
            else if try !startsConversion(), let unit = try UnitParser.tryParse(tokens, &position, knownNames) {
                expression = UnitExpressionNode(expression, unit, false)
                try compositeTail(&expression)
            }
            else { return expression }
        }
    }
    func startsConversion() throws -> Bool {
        if !current.text.equalsIgnoreCase("in") { return false }
        let saved = position; position += 1
        let lower = current.text.netLower
        var temporal = RateSyntax.tryKind(current.text) != nil || current.text == "(" || NetworkArithmetic.isFunction(current.text)
        temporal = temporal || current.text.equalsIgnoreCase("cidr") || current.text.equalsIgnoreCase("mask") || current.kind == .ip
        temporal = temporal || knownNameLength(position) > 0 || integerTarget()
        temporal = temporal || ["rgb", "hsl", "ratio", "aspect", "colors", "colours", "eng", "engineering"].contains(lower)
        temporal = temporal || ExpressionParser.earningsTarget(current.text) != nil || current.text.equalsIgnoreCase("unix")
        if !temporal { temporal = try tryZone(explicitTarget: true) != nil }
        if !temporal && (current.kind == .name || current.kind == .currency) { temporal = try CurrencyCatalog.tryMatch(tokens, position) != nil }
        position = saved
        if temporal { return true }
        var next = position + 1
        if try UnitParser.tryParse(tokens, &next, nil) == nil { return false }
        return next == tokens.count || tokens[next].kind != .name || tokens[next].text.equalsIgnoreCase("in") ||
            KeywordCatalog.match(tokens, next, .to) > 0 || KeywordCatalog.match(tokens, next, .leadingDecimals) > 0 || KeywordCatalog.match(tokens, next, .leadingSignificant) > 0
    }
    func atom() throws -> Expression {
        if current.text.equalsIgnoreCase("uuid") && (knownNameLength(position) == 0 || position + 1 < tokens.count && tokens[position + 1].text == "(") {
            let site = position; position += 1
            if take("(") && !take(")") { throw CalcError.format("uuid expects no arguments") }
            return UuidExpression(site)
        }
        if current.kind == .colour { let literal = current.text; position += 1; return ColourLiteralExpression(literal) }
        if current.kind == .codepoint { let literal = current.text; position += 1; return CallExpression("codepoint", [IntegerLiteralExpression("0x" + literal.netSubstring(2))]) }
        if current.kind == .aspect {
            let dimensions = current.text.netSplit("x"); position += 1
            return CallExpression("aspect", try dimensions.map { LiteralExpression(try Rational.parse($0)) })
        }
        if current.kind == .text {
            let quoted = current.text; var literalIndex = 0; position += 1
            return TextLiteralExpression(try TextSyntax.readQuoted(quoted, &literalIndex, cancellationToken))
        }
        if take("/") { return try parsePrefixMask() }
        if current.kind == .ip { let ip = current.text; position += 1; return IpLiteralExpression(ip) }
        if current.kind == .integer { let literal = current.text; position += 1; return IntegerLiteralExpression(literal) }
        if let chemistry = try tryChemistryAtom() { return chemistry }
        if let resistor = try tryResistorLiteral() { return resistor }
        if let money = try tryCurrencyPrefix() { return money }
        if take("[") { return try parseList() }
        if take("(") { let value = try rounded(); if !take(")") { throw CalcError.format("Expected )") }; return value }
        if knownNameLength(position) == 0 && (position + 1 >= tokens.count || tokens[position + 1].text != "(") {
            if take("now") { return NowExpression() }
            if take("unix") { return UnixExpression(try unary(), false) }
        }
        if current.kind == .time {
            let text = current.text; position += 1; var meridiem: String?
            if current.kind == .name && TimeSyntax.isMeridiem(current.text) { meridiem = current.text; position += 1 }
            return TimeLiteralExpression(try TimeSyntax.parse(text, meridiem))
        }
        if current.text.equalsIgnoreCase("from") && knownNameLength(position) == 0 && (position + 1 >= tokens.count || tokens[position + 1].text != "(") {
            position += 1; let start = try product()
            if !take("to") { throw CalcError.format("Expected to between clock endpoints") }
            return TimeRangeExpression(start, try product())
        }
        if knownNameLength(position) == 0, let (date, dateLength) = try DateSyntax.tryLiteral(tokens, position) { position += dateLength; return DateLiteralExpression(date) }
        if let calendarEvent = try tryCalendarEvent() { return calendarEvent }
        if let anchor = tryDateAnchor() { return anchor }
        if let imaginary = try tryImaginaryLiteral() { return imaginary }
        if current.kind == .number { return try number() }
        if current.kind != .name { throw CalcError.format("Expected expression") }
        let callSite = position
        var words: [String] = []; var best = 0; var nameLength = 0
        var end = position
        while end < tokens.count && tokens[end].kind == .name {
            nameLength += tokens[end].text.netLength + (end == position ? 0 : 1)
            if nameLength > 128 { break }
            words.append(tokens[end].text)
            if knownNames?.contains(words.joined(separator: " ")) == true { best = words.count }
            end += 1
        }
        words.removeAll()
        if best == 0 && (current.text.equalsIgnoreCase("prev") || SheetSyntax.isLineReference(current.text) != nil) { best = 1 }
        if best > 0 { for _ in 0..<best { words.append(current.text); position += 1 } }
        else {
            words.append(current.text); position += 1
            let valueName = words[0] == "i" || ConstantCatalog.tryFind(words[0]) != nil
            while current.kind == .name && !KeywordCatalog.isOf(current.text) && !current.text.equalsIgnoreCase("xor") && !(valueName && startsValueTail()) {
                words.append(current.text); position += 1
            }
        }
        let name = words.joined(separator: " ")
        if name.netLength > 128 { throw CalcError.format("Identifier limit exceeded") }
        if best == 0 && words.count == 1 && current.text != "(" && name == "i" { return ImaginaryExpression(Rational.one) }
        if best == 0 && words.count == 1 && current.text != "(" && ConstantCatalog.tryFind(name) != nil { return ConstantExpression(name) }
        if !take("(") { return NameExpression(name) }
        if best == 0 && CalculusSyntax.isFunction(name) { return try parseCalculus(name) }
        var args: [Expression] = []
        if !take(")") {
            repeat {
                args.append(try rounded())
                if args.count > 16 { throw CalcError.arithmetic("Argument limit exceeded") }
            } while take(",")
            if !take(")") { throw CalcError.format("Expected )") }
        }
        return CallExpression(name, args, site: callSite)
    }
    func knownNameLength(_ start: Int) -> Int {
        guard let knownNames, !knownNames.isEmpty else { return 0 }
        var words: [String] = []; var best = 0; var length = 0
        var end = start
        while end < tokens.count && tokens[end].kind == .name {
            length += tokens[end].text.netLength + (end == start ? 0 : 1)
            if length > 128 { break }
            words.append(tokens[end].text)
            if knownNames.contains(words.joined(separator: " ")) { best = words.count }
            end += 1
        }
        return best
    }
    func number() throws -> Expression {
        func makeGroup(_ cjkOnly: Bool) throws -> (node: Expression, coefficient: Rational, value: Rational, cjkExponent: Int) {
            try cancellationToken.throwIfCancellationRequested()
            let coefficient = try Rational.parse(current.text); position += 1
            var node: Expression = LiteralExpression(coefficient); var value = coefficient; var exponent = 0
            if current.kind == .name, let factor = NumberLanguage.tryMultiplier(current.text, current.joinedToPrevious) {
                exponent = NumberLanguage.cjkExponent(current.text)
                if cjkOnly && exponent == 0 { throw CalcError.format("Use descending CJK groups") }
                node = ScaleExpression(current.text, factor, node); value = try value * factor; position += 1
            }
            return (node, coefficient, value, exponent)
        }
        var group = try makeGroup(false); var expression = group.node
        while group.cjkExponent > 0 && current.kind == .number && current.joinedToPrevious {
            if !group.coefficient.denominator.isOne { throw CalcError.format("Only the final CJK group can be fractional") }
            let next = try makeGroup(true)
            let upper = BigInt.pow(10, group.cjkExponent)
            if next.cjkExponent >= group.cjkExponent || next.value.numerator >= upper * next.value.denominator { throw CalcError.format("Use descending CJK groups") }
            expression = BinaryExpression("+", expression, next.node); group = next
        }
        return expression
    }

    static func tokenize(_ text: String, _ cancellationToken: CancellationToken, _ knownNames: NetHashSet<String>? = nil) throws -> [Token] {
        let source = try TextSyntax.normalizeNatural(text, cancellationToken).units
        var dataCalls: [Bool]? = source.contains(0x22) ? [] : nil
        var tokens: [Token] = []
        var lastEnd = -1
        var i = 0
        func s(_ a: Int, _ b: Int) -> String { source.string(a, b) }
        while i < source.count {
            try cancellationToken.throwIfCancellationRequested()
            if tokens.count >= 4096 { throw CalcError.arithmetic("Expression token limit exceeded") }
            if NetChar.isWhiteSpace(source[i]) { i += 1; continue }
            let start = i
            let joined = start == lastEnd
            let c = source[i]
            if c == 0x22 {
                if let data = dataCalls?.last, data {
                    let value = try TextSyntax.readQuoted(source, &i, cancellationToken); tokens.append(Token(.text, TextValue.quote(value), joined))
                } else {
                    i += 1; var closed = false
                    while i < source.count {
                        if source[i] == 0x5C { i += 2; continue }
                        let x = source[i]; i += 1
                        if x == 0x22 { closed = true; break }
                    }
                    if !closed { throw CalcError.format("Unclosed quoted comment") }
                }
            } else if case let colourLength = DeveloperSyntax.colourLiteralLength(source, i), colourLength > 0 {
                i += colourLength; tokens.append(Token(.colour, s(start, i), joined))
            } else if knownNames?.contains("U") != true, case let cpLength = DeveloperSyntax.codepointLength(source, i), cpLength > 0 {
                i += cpLength; tokens.append(Token(.codepoint, s(start, i), joined))
            } else if let aspect = DeveloperSyntax.tryAspect(source, i) {
                i = aspect.end; tokens.append(Token(.aspect, aspect.dimensions, joined))
            } else if case let ipLength = ExpressionParser.ipLiteralLength(source, i), ipLength > 0 {
                i += ipLength; tokens.append(Token(.ip, s(start, i), joined))
            } else if c == 0x30 && i + 1 < source.count && [0x78, 0x58, 0x62, 0x42, 0x6F, 0x4F].contains(source[i + 1]) {
                i += 2; while i < source.count && (NetChar.isLetterOrDigit(source[i]) || source[i] == 0x5F) { i += 1 }
                if i - start > 8194 { throw CalcError.arithmetic("Integer literal length limit exceeded") }
                tokens.append(Token(.integer, s(start, i), joined))
            } else if c == 0x54 && joined && tokens.last?.kind == .date && TimeSyntax.literalLength(source, i + 1) > 0 {
                i += 1; tokens.append(Token(.symbol, "T", true))
            } else if case let timeLength = TimeSyntax.literalLength(source, i), timeLength > 0 {
                i += timeLength; tokens.append(Token(.time, s(start, i), joined))
            } else if case let dateLength = DateSyntax.isoLength(source, i), dateLength > 0 {
                i += dateLength; tokens.append(Token(.date, s(start, i), joined))
            } else if NetChar.isAsciiDigit(c) || c == 0x2E {
                while i < source.count && (NetChar.isAsciiDigit(source[i]) || source[i] == 0x2E) { i += 1 }
                let value = source[start..<i]
                if value.count > 256 || value.filter({ $0 == 0x2E }).count > 1 || !value.contains(where: NetChar.isAsciiDigit) { throw CalcError.format("Invalid number") }
                tokens.append(Token(.number, s(start, i), joined))
            } else if NumberLanguage.isCjkScale(c) && tokens.last?.kind == .number {
                tokens.append(Token(.name, String(unit: c), joined)); i += 1
            } else if c == 0xB0, case let symbolLength = UnitCatalog.symbolLength(source, i), symbolLength > 0 {
                i += symbolLength; tokens.append(Token(.name, s(start, i), joined))
            } else if NetChar.category(c) == .currencySymbol || NetChar.isLetter(c) && (i + 1 < source.count && source[i + 1] == 0x24 || i + 2 < source.count && source[i + 2] == 0x24),
                      case let currencyLength = CurrencyCatalog.symbolLength(source, i), currencyLength > 0 {
                i += currencyLength; tokens.append(Token(.currency, s(start, i), joined))
            } else if NetChar.isLetter(c) || c == 0x5F {
                let zoneLength = ZoneCatalog.idLength(source, i)
                if zoneLength > 0 { i += zoneLength; tokens.append(Token(.zone, s(start, i), joined)); lastEnd = i; continue }
                let keywordLength = KeywordCatalog.cjkTokenLength(source, i, knownNames)
                if keywordLength > 0 { i += keywordLength }
                else {
                    while i < source.count && (NetChar.isLetterOrDigit(source[i]) || source[i] == 0x5F || source[i] == 0xB2 || source[i] == 0xB3 ||
                                               (source[i] >= 0x2080 && source[i] <= 0x2089) || KeywordCatalog.isMark(source[i])) { i += 1 }
                }
                if i - start > 128 { throw CalcError.format("Identifier limit exceeded") }
                tokens.append(Token(.name, s(start, i), joined))
            } else {
                if c == 0x2013 || c == 0x2014 { i += 1; tokens.append(Token(.symbol, "–", joined)); lastEnd = i; continue }
                if c == 0x7C && i + 1 < source.count && source[i + 1] == 0x7C { i += 2; tokens.append(Token(.symbol, "||", joined)); lastEnd = i; continue }
                if (c == 0x3C || c == 0x3E) && i + 1 < source.count && source[i + 1] == c {
                    i += 2; if c == 0x3E && i < source.count && source[i] == 0x3E { i += 1 }
                    tokens.append(Token(.symbol, s(start, i), joined)); lastEnd = i; continue
                }
                if !"+-*/^!%(),[]·&|~".utf16.contains(c) { throw CalcError.format("Unexpected character") }
                if c == 0x28, dataCalls != nil { dataCalls!.append((dataCalls!.last ?? false) || TextSyntax.dataCallAt(source, i)) }
                else if c == 0x29, dataCalls != nil, !dataCalls!.isEmpty { dataCalls!.removeLast() }
                tokens.append(Token(.symbol, String(unit: c), joined)); i += 1
            }
            lastEnd = i
        }
        return tokens
    }
}

// Nodes the shared parser spine builds for usage rates and earnings (RateExpressions.cs, EarningsExpressions.cs).
final class UsageCountExpression: Expression {
    let operand: Expression, kind: UsageKind
    init(_ operand: Expression, _ kind: UsageKind) { self.operand = operand; self.kind = kind }
    var children: [Expression] { [operand] }
}
final class UsagePriceExpression: Expression {
    let operand: Expression, perCount: Rational, kind: UsageKind?
    init(_ operand: Expression, _ perCount: Rational, _ kind: UsageKind?) { self.operand = operand; self.perCount = perCount; self.kind = kind }
    func with(operand: Expression) -> UsagePriceExpression { UsagePriceExpression(operand, perCount, kind) }
    var children: [Expression] { [operand] }
}
final class UsageConvertExpression: Expression {
    let operand: Expression, kind: UsageKind, unit: UnitExpression?
    init(_ operand: Expression, _ kind: UsageKind, _ unit: UnitExpression?) { self.operand = operand; self.kind = kind; self.unit = unit }
    var children: [Expression] { [operand] }
}
final class RateForExpression: Expression {
    let rate: Expression, duration: Expression
    init(_ rate: Expression, _ duration: Expression) { self.rate = rate; self.duration = duration }
    var children: [Expression] { [rate, duration] }
}
final class EarningsAttachExpression: Expression {
    let operand: Expression, period: EarningsPeriod
    init(_ operand: Expression, _ period: EarningsPeriod) { self.operand = operand; self.period = period }
    var children: [Expression] { [operand] }
}
final class EarningsConvertExpression: Expression {
    let operand: Expression, period: EarningsPeriod
    init(_ operand: Expression, _ period: EarningsPeriod) { self.operand = operand; self.period = period }
    var children: [Expression] { [operand] }
}
