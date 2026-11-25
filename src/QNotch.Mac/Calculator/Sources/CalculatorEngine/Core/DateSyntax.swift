import Foundation

enum DateSyntax {
    private static let months: NetDictionary<String, Int> = {
        var map = NetDictionary<String, Int>.ignoringCase()
        let names = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        for (index, name) in names.enumerated() { map.set(name, index + 1); map.set(String(name.prefix(3)), index + 1) }
        map.set("sept", 9)
        return map
    }()
    static func isoLength(_ source: [UInt16], _ start: Int) -> Int {
        if source.count - start < 7 || source[start + 4] != 0x2D { return 0 }
        for index in 0..<4 where !NetChar.isAsciiDigit(source[start + index]) { return 0 }
        var cursor = start + 5; let monthStart = cursor
        while cursor < source.count && cursor - monthStart < 3 && NetChar.isAsciiDigit(source[cursor]) { cursor += 1 }
        if cursor == monthStart || cursor >= source.count || source[cursor] != 0x2D { return 0 }
        cursor += 1; let dayStart = cursor
        while cursor < source.count && cursor - dayStart < 3 && NetChar.isAsciiDigit(source[cursor]) { cursor += 1 }
        return cursor == dayStart ? 0 : cursor - start
    }
    static func tryLiteral(_ tokens: [Token], _ position: Int) throws -> (date: DateOnly, length: Int)? {
        if position >= tokens.count { return nil }
        if tokens[position].kind == .date {
            guard let date = DateOnly.parseISO(tokens[position].text) else { throw CalcError.format("Invalid Gregorian date") }
            return (date, 1)
        }
        var cursor = position
        let day: String, year: String, month: Int
        if let m = months[tokens[cursor].text] {
            month = m
            cursor += 1
            if cursor >= tokens.count || tokens[cursor].kind != .number { return nil }
            day = tokens[cursor].text; cursor += 1
            if cursor < tokens.count && tokens[cursor].text == "," { cursor += 1 }
            if cursor >= tokens.count || tokens[cursor].kind != .number { return nil }
            year = tokens[cursor].text; cursor += 1
        } else {
            guard cursor + 2 < tokens.count, tokens[cursor].kind == .number, let m = months[tokens[cursor + 1].text], tokens[cursor + 2].kind == .number else { return nil }
            month = m; day = tokens[cursor].text; year = tokens[cursor + 2].text; cursor += 3
        }
        guard let d = TimeSyntax.parseDigits(day), year.netLength == 4, let y = TimeSyntax.parseDigits(year) else { throw CalcError.format("Date requires a day and four-digit year") }
        guard let date = DateOnly(y, month, d) else { throw CalcError.format("Invalid Gregorian date") }
        return (date, cursor - position)
    }
    static func isNaturalStart(_ tokens: [Token], _ names: NetHashSet<String>) throws -> Bool {
        if tokens.isEmpty || names.contains(tokens.map(\.text).joined(separator: " ")) { return false }
        let first = tokens[0].text.netLower, second = tokens.count > 1 ? tokens[1].text.netLower : ""
        if names.contains(tokens[0].text) || second == "(" { return false }
        if ExpressionParser.workdayPrefix(tokens, 0) != nil { return true }
        if ["today", "tomorrow", "yesterday", "christmas", "until"].contains(first) || first == "in" ||
            DayOfWeek.netTryParse(first) != nil || first == "new" && (second == "year" || second == "years") { return true }
        if try tryRecurringLiteral(tokens, 0) != nil { return true }
        return
            (first == "days" || first == "weeks") && ["between", "since", "until"].contains(second) || first == "age" && second == "of" ||
            (first == "next" || first == "last") && DayOfWeek.netTryParse(second) != nil
    }
    static func tryRecurringLiteral(_ tokens: [Token], _ position: Int) throws -> (month: Int, day: Int, length: Int)? {
        if position + 1 >= tokens.count { return nil }
        let dayText: String, month: Int
        if let m = months[tokens[position].text], tokens[position + 1].kind == .number { month = m; dayText = tokens[position + 1].text }
        else if tokens[position].kind == .number, let m = months[tokens[position + 1].text] { month = m; dayText = tokens[position].text }
        else { return nil }
        guard let day = TimeSyntax.parseDigits(dayText), day >= 1, day <= DateOnly.daysInMonth(2000, month) else { throw CalcError.format("Invalid recurring Gregorian date") }
        return (month, day, 2)
    }
}

final class DateArithmetic {
    private static let time = Dimension(0, 0, 1, 0, 0, 0, 0, 0)
    let context: EvaluationContext
    init(_ context: EvaluationContext) { self.context = context }
    func anchor(_ expression: DateAnchorExpression) throws -> SheetValue {
        let today = try context.requireToday(); var offset = expression.offset
        if let weekday = expression.weekday {
            let distance = expression.direction > 0 ? (weekday.rawValue - today.dayOfWeek.rawValue + 7) % 7 : (today.dayOfWeek.rawValue - weekday.rawValue + 7) % 7
            offset = (distance == 0 ? 7 : distance) * expression.direction
        }
        return try DateArithmetic.move(today, CalendarPeriod(0, offset))
    }
    private static func integer(_ value: Rational, _ limit: Int) throws -> Int {
        if !value.denominator.isOne || value.numerator.magnitude > BigInt(limit) { throw CalcError.arithmetic("Calendar arithmetic requires bounded whole counts") }
        return value.numerator.intValue!
    }
    static func days(_ value: SheetValue) throws -> Int {
        let number = try value.number
        if number.unit?.dimension != time || number.isPercentage || !number.isRational || number.isApproximate { throw CalcError.arithmetic("Expected an exact whole-day duration") }
        return try integer(number.exact.rational / Rational(86400), 3_660_000)
    }
    private static func period(_ value: SheetValue) throws -> CalendarPeriod { value.kind == .calendarPeriod ? try value.period : CalendarPeriod(0, try days(value)) }
    static func monthPeriod(_ count: SheetValue, _ factor: Int) throws -> SheetValue {
        if try count.isPercentage || count.number.isApproximate { throw CalcError.arithmetic("Calendar count must be an exact plain rational") }
        return try .period(CalendarPeriod(integer(count.scalar * Rational(factor), 120_000), 0))
    }
    static func shift(_ date: SheetValue, _ offset: SheetValue, _ direction: Int) throws -> SheetValue {
        let period = try period(offset)
        return try move(try date.date, direction < 0 ? CalendarPeriod(-period.months, -period.days) : period)
    }
    private static func move(_ date: DateOnly, _ period: CalendarPeriod) throws -> SheetValue {
        guard let moved = date.addingMonths(period.months)?.addingDays(period.days) else { throw CalcError.arithmetic("Date range exceeded (0001-01-01 through 9999-12-31)") }
        return .date(moved)
    }
    static func negate(_ value: SheetValue) throws -> SheetValue {
        if value.kind != .calendarPeriod { throw CalcError.arithmetic("A date cannot be negated") }
        let p = try value.period
        return try .period(CalendarPeriod(-p.months, -p.days))
    }
    func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue {
        if left.kind == .date && right.kind == .date {
            if operation != "-" { throw CalcError.arithmetic("Only subtraction is defined between dates") }
            return try DateArithmetic.duration(try left.date.dayNumber - right.date.dayNumber, false)
        }
        if left.kind == .date || right.kind == .date {
            if operation != "+" && operation != "-" || right.kind == .date && operation == "-" { throw CalcError.arithmetic("Invalid date arithmetic") }
            let date = left.kind == .date ? try left.date : try right.date
            let period = try DateArithmetic.period(left.kind == .date ? right : left)
            return try DateArithmetic.move(date, operation == "-" ? CalendarPeriod(-period.months, -period.days) : period)
        }
        if operation == "+" || operation == "-" {
            let a = try DateArithmetic.period(left), b = try DateArithmetic.period(right); let sign = operation == "+" ? 1 : -1
            return try .period(CalendarPeriod(a.months + sign * b.months, a.days + sign * b.days))
        }
        if operation == "*" || operation == "/" {
            let period = left.kind == .calendarPeriod ? try left.period : try right.period
            if operation == "/" && left.kind != .calendarPeriod { throw CalcError.arithmetic("Cannot divide by a calendar period") }
            let number = left.kind == .calendarPeriod ? try right.number : try left.number
            if number.isPercentage { throw CalcError.arithmetic("Calendar scaling requires a plain rational") }
            let scale = try number.scalar
            let months = operation == "/" ? try Rational(period.months) / scale : try Rational(period.months) * scale
            let days = operation == "/" ? try Rational(period.days) / scale : try Rational(period.days) * scale
            return try .period(CalendarPeriod(DateArithmetic.integer(months, 120_000), DateArithmetic.integer(days, 3_660_000)))
        }
        throw CalcError.arithmetic("Unsupported calendar operation")
    }
    static func duration(_ days: Int, _ weeks: Bool) throws -> SheetValue {
        let unit = try UnitExpression.single(UnitCatalog.byId(weeks ? "week" : "day"))
        return .number(NumericValue(ExactNumber(Rational(Int64(days) * 86400)), unit: unit))
    }
    static func interval(_ kind: String, _ from: SheetValue, _ to: SheetValue) throws -> SheetValue {
        let start = try from.date, end = try to.date
        if kind == "age" {
            if end < start { throw CalcError.arithmetic("Age endpoint precedes the starting date") }
            var years = end.year - start.year
            if let anniversary = start.addingYears(years), anniversary > end { years -= 1 }
            return .number(NumericValue(Rational(years)))
        }
        return try duration(end.dayNumber - start.dayNumber, kind == "weeks")
    }
}
