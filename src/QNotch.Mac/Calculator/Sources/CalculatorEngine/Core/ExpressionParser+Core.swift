import Foundation

// Parser pieces that C# keeps in DateExpressions, ListExpressions, CurrencyExpressions, ZoneExpressions,
// CountdownExpressions, WorkdayExpressions, IntegerExpressions, NetworkExpressions, ComplexExpressions,
// RateExpressions and EarningsExpressions: the shared spine every sheet line goes through.

enum EarningsPeriod: Int, Hashable { case hour = 0, day, month, year }
enum UsageKind: Int, Hashable { case items = 0, tokens, requests }

enum RateSyntax {
    static func tryKind(_ text: String) -> UsageKind? {
        switch text.netLower {
        case "token", "tokens": return .tokens
        case "request", "requests", "req": return .requests
        case "item", "items": return .items
        default: return nil
        }
    }
    static func trySpeedUnit(_ text: String) throws -> UnitExpression? {
        let u = text.units
        if u.count < 3 || u.count > 7 || !text.hasSuffix("ps") { return nil }
        let prefix = Array(u[..<(u.count - 2)]); let suffix = prefix[prefix.count - 1]
        if suffix != 0x62 && suffix != 0x42 { return nil }
        let scale = prefix[..<(prefix.count - 1)].string
        if !["", "k", "M", "G", "T", "P", "E", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei"].contains(scale) { return nil }
        let id = suffix == 0x62 ? scale + "bit" : scale + "B"
        return try UnitExpression.single(UnitCatalog.byId(id)).combine(.single(UnitCatalog.byId("s")), -1)
    }
}

extension ExpressionParser {
    // MARK: Dates (DateExpressions.cs)

    func tryDateAnchor() -> Expression? {
        if knownNameLength(position) > 0 || position + 1 < tokens.count && tokens[position + 1].text == "(" { return nil }
        let text = current.text.netLower
        if text == "today" || text == "tomorrow" || text == "yesterday" {
            position += 1; return DateAnchorExpression(offset: text == "today" ? 0 : text == "tomorrow" ? 1 : -1)
        }
        if (text == "next" || text == "last") && position + 1 < tokens.count && tokens[position + 1].kind == .name, let weekday = DayOfWeek.netTryParse(tokens[position + 1].text) {
            position += 2
            // Name tokens never parse as numbers, so Enum.TryParse only accepted a day name here.
            return DateAnchorExpression(weekday: DayOfWeek(rawValue: weekday)!, direction: text == "next" ? 1 : -1)
        }
        return nil
    }
    func tryCalendarSuffix(_ expression: inout Expression) -> Bool {
        if current.kind != .name || knownNameLength(position) > 0 { return false }
        let text = current.text.netLower
        if !["month", "months", "year", "years"].contains(text) { return false }
        position += 1; expression = CalendarPeriodExpression(expression, text == "year" || text == "years" ? 12 : 1)
        return true
    }
    func compositeTail(_ expression: inout Expression) throws {
        while current.kind == .number {
            let start = position; var next = try number()
            if !tryCalendarSuffix(&next) {
                guard let unit = try UnitParser.tryParse(tokens, &position, knownNames) else { position = start; break }
                next = UnitExpressionNode(next, unit, false)
            }
            expression = BinaryExpression("+", expression, next)
        }
    }
    func tryDateSentence() throws -> Expression? {
        if tokens.isEmpty || knownNames?.contains(tokens.map(\.text).joined(separator: " ")) == true { return nil }
        func separator(_ word: String, _ start: Int) -> Int {
            var nesting = 0
            for index in start..<max(start, tokens.count) {
                if tokens[index].text == "(" { nesting += 1 }
                else if tokens[index].text == ")" { nesting -= 1 }
                else if nesting == 0 && tokens[index].text.equalsIgnoreCase(word) { return index }
            }
            return -1
        }
        let first = tokens[0].text.netLower, second = tokens.count > 1 ? tokens[1].text.netLower : ""
        if tokens.count > 1 && tokens[tokens.count - 1].text.equalsIgnoreCase("ago") {
            return DateShiftExpression(DateAnchorExpression(), try part(0, tokens.count - 1), -1)
        }
        if knownNameLength(0) > 0 || second == "(" { return nil }
        if first == "in" && tokens.count > 1 { return DateShiftExpression(DateAnchorExpression(), try part(1, tokens.count - 1), 1) }
        if (first == "days" || first == "weeks") && ["between", "since", "until"].contains(second) {
            let from: Expression, to: Expression
            if second == "between" {
                let split = separator("and", 2)
                if split < 0 { throw CalcError.format("Expected and between date endpoints") }
                from = try part(2, split - 2); to = try part(split + 1, tokens.count - split - 1)
            } else {
                let endpoint = try part(2, tokens.count - 2); let today = DateAnchorExpression()
                from = second == "since" ? endpoint : today; to = second == "since" ? today : endpoint
            }
            return DateIntervalExpression(first, from, to)
        }
        if first == "age" && second == "of" {
            let split = separator("on", 2)
            return DateIntervalExpression("age", try part(2, split < 0 ? tokens.count - 2 : split - 2), split < 0 ? DateAnchorExpression() : try part(split + 1, tokens.count - split - 1))
        }
        return nil
    }

    // MARK: Lists (ListExpressions.cs)

    func parseList() throws -> Expression {
        var entries: [Expression] = []
        if !take("]") {
            repeat {
                if entries.count >= SheetList.maxItems { throw CalcError.arithmetic("List exceeds 1024 values") }
                if let recurring = try DateSyntax.tryRecurringLiteral(tokens, position), position + recurring.length < tokens.count,
                   tokens[position + recurring.length].text == "," || tokens[position + recurring.length].text == "]" {
                    position += recurring.length; entries.append(AnnualHolidayExpression(recurring.month, recurring.day))
                } else { entries.append(try rounded()) }
            } while take(",")
            if !take("]") { throw CalcError.format("Expected ] after list values") }
        }
        return ListExpression(entries)
    }

    // MARK: Currency (CurrencyExpressions.cs)

    func tryCurrencySuffix(_ expression: inout Expression) throws -> Bool {
        if current.kind != .name && current.kind != .currency || knownNameLength(position) > 0 { return false }
        guard let (currency, length) = try CurrencyCatalog.tryMatch(tokens, position) else { return false }
        position += length; expression = CurrencyAttachExpression(expression, currency.code); return true
    }
    func tryCurrencyPrefix() throws -> Expression? {
        if current.kind != .name && current.kind != .currency || knownNameLength(position) > 0 { return nil }
        guard let (currency, length) = try CurrencyCatalog.tryMatch(tokens, position) else { return nil }
        let next = position + length
        if next < tokens.count && tokens[next].text == "(" && length == 1 && FunctionLibrary.isBuiltin(current.text) { return nil }
        if next >= tokens.count || tokens[next].kind != .number && tokens[next].text != "(" && tokens[next].text != "+" && tokens[next].text != "-" { return nil }
        position = next; let operand = try unary()
        if let price = operand as? UsagePriceExpression { return price.with(operand: CurrencyAttachExpression(price.operand, currency.code)) }
        return CurrencyAttachExpression(operand, currency.code)
    }
    func tryCurrencyConversion(_ expression: inout Expression) throws -> Bool {
        if current.kind != .name && current.kind != .currency { return false }
        guard let (currency, length) = try CurrencyCatalog.tryMatch(tokens, position) else { return false }
        position += length
        var unit: UnitExpression?
        if try !startsConversion(), let parsed = try UnitParser.tryParse(tokens, &position, knownNames) { unit = parsed }
        var date: Expression?
        if take("on") {
            var end = position, nesting = 0
            while end < tokens.count {
                let text = tokens[end].text
                if nesting == 0 && (text == "," || text == ")" || text == "]") { break }
                if text == "(" || text == "[" { nesting += 1 } else if text == ")" || text == "]" { nesting -= 1 }
                end += 1
            }
            date = try sub(position, end - position).parse()
            position = end
        }
        expression = CurrencyConvertExpression(expression, currency.code, unit: unit, date: date); return true
    }

    // MARK: Zones and timestamps (ZoneExpressions.cs)

    func tryZone(explicitTarget: Bool = false) throws -> String? {
        if !explicitTarget && knownNameLength(position) > 0 { return nil }
        if current.kind == .zone { let zone = current.text; position += 1; return zone }
        var text = ""; var best = position; var id = ""
        var cursor = position
        while cursor < tokens.count && cursor - position < 16 && (tokens[cursor].kind == .name || tokens[cursor].text == "-") {
            if cursor + 1 < tokens.count && tokens[cursor + 1].text == "(" { break }
            text += (cursor == position || tokens[cursor].joinedToPrevious ? "" : " ") + tokens[cursor].text
            if let candidate = ZoneCatalog.tryAlias(text) { best = cursor + 1; id = candidate }
            cursor += 1
        }
        if best == position { return nil }
        position = best; var zone = id
        if zone == "UTC" && current.joinedToPrevious && (current.text == "+" || current.text == "-") && position + 1 < tokens.count && tokens[position + 1].kind == .time {
            let sign = current.text; position += 1
            if current.kind != .time { throw CalcError.format("UTC offset requires ±HH:mm[:ss]") }
            zone += sign + current.text; position += 1
        }
        return zone
    }
    func tryTimestampTail(_ expression: inout Expression) throws -> Bool {
        if current.kind == .time || current.kind == .symbol && current.text == "T" || current.text.equalsIgnoreCase("at") && knownNameLength(position) == 0 {
            if current.kind != .time { position += 1 }
            let right = try unary(false)
            expression = TimestampJoinExpression(expression, right); return true
        }
        let start = position
        if let zone = try tryZone() {
            let zoneEnd = position; var unitEnd = start
            if let unit = try UnitParser.tryParse(tokens, &unitEnd, knownNames), unitEnd == zoneEnd {
                expression = UnitOrZoneExpression(expression, zone, unit, false); return true
            }
            let lower = current.text.netLower
            let ambiguity = lower == "earlier" || lower == "later" ? lower : ""
            if !ambiguity.isEmpty { position += 1 }
            expression = ZoneExpression(expression, zone, false, ambiguity); return true
        }
        // ISO offsets bind only when adjacent to a timestamp/closing parenthesis, never ordinary clock subtraction.
        if current.joinedToPrevious && (current.text == "+" || current.text == "-") && position + 1 < tokens.count && tokens[position + 1].kind == .time && expression is TimestampJoinExpression {
            let zone = "UTC" + current.text + tokens[position + 1].text; position += 2
            expression = ZoneExpression(expression, zone, false); return true
        }
        return false
    }

    // MARK: Countdowns (CountdownExpressions.cs)

    func tryCalendarEvent() throws -> Expression? {
        if knownNameLength(position) > 0 || position + 1 < tokens.count && tokens[position + 1].text == "(" { return nil }
        if current.kind == .name, let day = DayOfWeek.netTryParse(current.text) { position += 1; return CalendarEventExpression(weekday: DayOfWeek(rawValue: day)!) }
        if take("christmas") { return CalendarEventExpression(month: 12, day: 25) }
        if current.text.equalsIgnoreCase("new") && position + 1 < tokens.count && ["year", "years"].contains(tokens[position + 1].text.netLower) {
            position += 2; _ = take("day"); return CalendarEventExpression(month: 1, day: 1)
        }
        if let recurring = try DateSyntax.tryRecurringLiteral(tokens, position) {
            position += recurring.length; return CalendarEventExpression(month: recurring.month, day: recurring.day)
        }
        return nil
    }
    func startsCountdown() -> Bool {
        current.text.equalsIgnoreCase("until") && knownNameLength(position) == 0 && (position + 1 >= tokens.count || tokens[position + 1].text != "(")
    }
    func parseCountdown() throws -> Expression {
        position += 1; var deadline = try sum()
        while true {
            let saved = position
            if !(take("in") || take("to")) { break }
            guard let zone = try tryZone(explicitTarget: true) else { position = saved; break }
            let lower = current.text.netLower
            let ambiguity = lower == "earlier" || lower == "later" ? lower : ""
            if !ambiguity.isEmpty { position += 1 }
            deadline = CountdownZoneExpression(deadline, zone, ambiguity)
        }
        return try roundingTail(CountdownExpression(deadline))
    }

    // MARK: Working days (WorkdayExpressions.cs)

    static func workdayPrefix(_ values: [Token], _ at: Int) -> Int? {
        if at >= values.count { return nil }
        let word = values[at].text.netLower
        if word == "workday" || word == "workdays" { return 1 }
        if (word == "working" || word == "business") && at + 1 < values.count && ["day", "days"].contains(values[at + 1].text.netLower) { return 2 }
        return nil
    }
    func tryWorkdaySuffix(_ expression: inout Expression) -> Bool {
        if knownNameLength(position) > 0 { return false }
        guard let length = ExpressionParser.workdayPrefix(tokens, position) else { return false }
        position += length; expression = WorkdayPeriodExpression(expression); return true
    }
    func tryWorkdaySentence() throws -> Expression? {
        if tokens.isEmpty || knownNameLength(0) > 0 { return nil }
        guard let length = ExpressionParser.workdayPrefix(tokens, 0), length < tokens.count else { return nil }
        let word = tokens[length].text.netLower
        if word == "between" {
            var nesting = 0, split = -1
            for index in (length + 1)..<max(length + 1, tokens.count) {
                if tokens[index].text == "(" { nesting += 1 }
                else if tokens[index].text == ")" { nesting -= 1 }
                else if nesting == 0 && tokens[index].text.equalsIgnoreCase("and") { split = index; break }
            }
            if split < 0 { throw CalcError.format("Expected and between working-day endpoints") }
            return WorkdayCountExpression(try part(length + 1, split - length - 1), try part(split + 1, tokens.count - split - 1))
        }
        if word == "since" || word == "until" {
            let date = try part(length + 1, tokens.count - length - 1); let today = DateAnchorExpression()
            return word == "since" ? WorkdayCountExpression(date, today) : WorkdayCountExpression(today, date)
        }
        if word == "in" {
            // A first-of-month literal gives strict month/year validation without reading the host clock.
            let monthTokens = [Token(.number, "1")] + tokens[(length + 1)...]
            if let (first, consumed) = try DateSyntax.tryLiteral(monthTokens, 0), consumed == monthTokens.count {
                return WorkdayCountExpression(DateLiteralExpression(first), DateLiteralExpression(DateOnly(first.year, first.month, DateOnly.daysInMonth(first.year, first.month))!))
            }
            if length + 2 == tokens.count && tokens[length + 1].text.netLength == 4, let year = Int32(tokens[length + 1].text), year >= 1, year <= 9999 {
                return WorkdayCountExpression(DateLiteralExpression(DateOnly(Int(year), 1, 1)!), DateLiteralExpression(DateOnly(Int(year), 12, 31)!))
            }
            throw CalcError.format("Expected month and four-digit year, or year after working days in")
        }
        return nil
    }

    // MARK: Integers (IntegerExpressions.cs)

    static func integerBase(_ text: String) -> Int? {
        switch text.netLower {
        case "hex", "hexadecimal": return 16
        case "bin", "binary": return 2
        case "oct", "octal": return 8
        case "dec", "decimal": return 10
        default: return nil
        }
    }
    static func wordType(_ text: String) -> (width: Int, signed: Bool)? {
        let u = text.units
        guard u.count > 1 else { return nil }
        let signed = u[0] == 0x69 || u[0] == 0x49
        guard signed || u[0] == 0x75 || u[0] == 0x55 else { return nil }
        let rest = u[1...]
        guard rest.allSatisfy(NetChar.isAsciiDigit), let width = Int32(String(units: rest)) else { return nil }
        return (Int(width), signed)
    }
    func integerTarget() -> Bool { ExpressionParser.integerBase(current.text) != nil || ExpressionParser.wordType(current.text) != nil }
    func tryIntegerConversion(_ expression: inout Expression) throws -> Bool {
        var radix = ExpressionParser.integerBase(current.text); var width: Int?; var signed = false
        if radix != nil { position += 1 }
        if let word = ExpressionParser.wordType(current.text) { width = word.width; signed = word.signed; position += 1; if radix == nil { radix = 10 } }
        else if radix != nil && current.kind == .number && position + 1 < tokens.count && tokens[position + 1].text.equalsIgnoreCase("bits") {
            guard let w = Int32(current.text.netTrim) else { throw CalcError.format("Expected whole integer width") }
            width = Int(w); position += 2
        }
        guard let radix else { return false }
        if let width, width < 1 || width > IntegerValue.maximumBits { throw CalcError.arithmetic("Integer width must be 1–4096 bits") }
        expression = IntegerConvertExpression(expression, radix, width, signed); return true
    }
    func bitOr() throws -> Expression { var value = try bitXor(); while take("|") { value = BinaryExpression("|", value, try bitXor()) }; return value }
    func bitXor() throws -> Expression { var value = try bitAnd(); while take("xor") { value = BinaryExpression("xor", value, try bitAnd()) }; return value }
    func bitAnd() throws -> Expression { var value = try shift(); while take("&") { value = BinaryExpression("&", value, try shift()) }; return value }
    func shift() throws -> Expression {
        var value = try sum()
        while ["<<", ">>", ">>>"].contains(current.text) { let op = current.text; position += 1; value = BinaryExpression(op, value, try sum()) }
        return value
    }

    // MARK: Networks (NetworkExpressions.cs)

    static func ipLiteralLength(_ source: [UInt16], _ start: Int) -> Int {
        // Check the shape before other numeric/date grammars; ordinary clocks retain their existing tokens.
        var i = start
        while i < source.count && (NetChar.isLetterOrDigit(source[i]) || source[i] == 0x2E || source[i] == 0x3A || source[i] == 0x25 || source[i] == 0x5F) {
            if i - start >= 128 { break }
            i += 1
        }
        let candidate = source[start..<i]
        let dots = candidate.filter { $0 == 0x2E }.count, colons = candidate.filter { $0 == 0x3A }.count
        let doubleColon = zip(candidate, candidate.dropFirst()).contains { $0 == 0x3A && $1 == 0x3A }
        return dots >= 3 || colons >= 3 || doubleColon ? i - start : 0
    }
    func tryNetworkConversion(_ expression: inout Expression, _ membershipAllowed: Bool) throws -> Bool {
        if take("cidr") { expression = CallExpression("cidr", [expression]); return true }
        if take("mask") { expression = CallExpression("subnetmask", [expression]); return true }
        if !membershipAllowed { return false }
        var starts = current.kind == .ip || current.text == "(" || NetworkArithmetic.isFunction(current.text) && position + 1 < tokens.count && tokens[position + 1].text == "("
        if !starts && knownNameLength(position) > 0 {
            var probe = position; let saved = position; let zone = try tryZone(explicitTarget: true) != nil; position = saved
            starts = !zone && !["eng", "engineering", "colors", "colours", "unix"].contains(current.text.netLower)
            if starts { starts = try UnitParser.tryParse(tokens, &probe, nil) == nil }
            if starts { starts = !integerTarget() }
            if starts { starts = try CurrencyCatalog.tryMatch(tokens, position) == nil }
            if starts { starts = ExpressionParser.earningsTarget(current.text) == nil }
        }
        if !starts { return false }
        expression = NetworkMembershipExpression(expression, try product()); return true
    }
    func parsePrefixMask() throws -> Expression {
        guard current.kind == .number, let parsed = Int32(current.text) else { throw CalcError.format("Expected a whole CIDR prefix") }
        let prefix = Int(parsed)
        position += 1; var family = 4
        if take("ipv6") { family = 6 } else { _ = take("ipv4") }
        if !take("mask") { throw CalcError.format("Expected mask after /prefix") }
        if prefix < 0 || prefix > (family == 4 ? 32 : 128) { throw CalcError.arithmetic("Prefix is outside the address family's bit width") }
        return PrefixMaskExpression(prefix, family)
    }

    // MARK: Complex numbers (ComplexExpressions.cs)

    /// A number joined to a lowercase i, as in 4i. A variable named i keeps the old meaning.
    func tryImaginaryLiteral() throws -> Expression? {
        if current.kind != .number || position + 1 >= tokens.count { return nil }
        let suffix = tokens[position + 1]
        if suffix.kind != .name || suffix.text != "i" || !suffix.joinedToPrevious || knownNameLength(position + 1) > 0 { return nil }
        let imaginary = ImaginaryExpression(try Rational.parse(current.text)); position += 2; return imaginary
    }
    /// A constant or i ends at a conversion or rounding tail instead of absorbing it into a multi-word name.
    func startsValueTail() -> Bool {
        current.text.equalsIgnoreCase("in") || KeywordCatalog.match(tokens, position, .to) > 0 ||
            KeywordCatalog.match(tokens, position, .leadingDecimals) > 0 || KeywordCatalog.match(tokens, position, .leadingSignificant) > 0
    }

    // MARK: Usage rates (RateExpressions.cs)

    func tryUsageConversion(_ expression: inout Expression) throws -> Bool {
        guard let kind = RateSyntax.tryKind(current.text) else { return false }
        position += 1; var unit: UnitExpression?
        if let parsed = try UnitParser.tryParse(tokens, &position, nil) { unit = parsed }
        expression = UsageConvertExpression(expression, kind, unit); return true
    }
    func tryUsageSuffix(_ expression: inout Expression) throws -> Bool {
        if knownNameLength(position) > 0 { return false }
        if let kind = RateSyntax.tryKind(current.text), !(position + 1 < tokens.count && tokens[position + 1].text == "(") {
            position += 1; expression = UsageCountExpression(expression, kind); return true
        }
        if current.text.equalsIgnoreCase("uptime") { position += 1; expression = CallExpression("uptime", [expression]); return true }
        if current.text == "/" || current.text.equalsIgnoreCase("per") {
            let saved = position; position += 1
            if current.text == "M" && knownNameLength(position) == 0 {
                position += 1; var priceKind: UsageKind?
                if knownNameLength(position) == 0, let explicitKind = RateSyntax.tryKind(current.text) { priceKind = explicitKind; position += 1 }
                expression = UsagePriceExpression(expression, Rational(1_000_000), priceKind); return true
            }
            position = saved
        }
        return false
    }

    // MARK: Earnings (EarningsExpressions.cs)

    static func earningsTarget(_ text: String) -> EarningsPeriod? {
        switch text.netLower {
        case "hourly": return .hour
        case "daily": return .day
        case "monthly": return .month
        case "yearly", "annually": return .year
        default: return nil
        }
    }
    func tryCalendarEarningsSuffix(_ expression: inout Expression) -> Bool {
        let saved = position
        if knownNameLength(position) > 0 { return false }
        if take("/") || take("per") {
            let word = current.text.netLower
            if knownNameLength(position) == 0 && (word == "month" || word == "year") {
                position += 1; expression = EarningsAttachExpression(expression, word == "month" ? .month : .year); return true
            }
        } else if ["monthly", "yearly", "annually"].contains(current.text.netLower) {
            let period = ExpressionParser.earningsTarget(current.text)!; position += 1; expression = EarningsAttachExpression(expression, period); return true
        }
        position = saved; return false
    }
}

