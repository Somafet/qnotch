import Foundation

final class WorkdayArithmetic {
    let budget: ExecutionBudget, token: CancellationToken
    private struct YearKey: Hashable { let calendar: WorkdayCalendar, year: Int }
    /// Holiday dates per (calendar, year), in the calendar's order, plus a set for lookups.
    private var years: [YearKey: (dates: [DateOnly], set: Set<DateOnly>)] = [:]
    init(_ budget: ExecutionBudget, _ token: CancellationToken) { self.budget = budget; self.token = token }

    private func holidays(_ calendar: WorkdayCalendar, _ year: Int) throws -> (dates: [DateOnly], set: Set<DateOnly>) {
        let key = YearKey(calendar: calendar, year: year)
        if let found = years[key] { return found }
        if years.count >= 100 { throw CalcError.arithmetic("Working-day calendar cache limit exceeded") }
        try budget.step(token)
        let holidays = try calendar.holidays(year)
        for _ in holidays { try budget.step(token) }
        let dates = holidays.map(\.date)
        let entry = (dates, Set(dates))
        years[key] = entry
        return entry
    }

    static func count(_ value: SheetValue) throws -> Int {
        let number = try value.number
        let error = CalcError.arithmetic("Working days require a plain whole count from -10,000 to 10,000")
        if number.unit != nil || number.isPercentage || !number.isRational || number.isApproximate { throw error }
        let scalar = try number.scalar
        if !scalar.denominator.isOne || scalar.numerator.magnitude > BigInt(WorkdayPeriod.maxCount) { throw error }
        return scalar.numerator.intValue!
    }

    private static func isWeekday(_ date: DateOnly) -> Bool { date.dayOfWeek != .saturday && date.dayOfWeek != .sunday }

    /// Moves over `period.count` working days; the origin is excluded and a zero count keeps it.
    func shift(_ start: DateOnly, _ period: WorkdayPeriod) throws -> SheetValue {
        let calendar = period.calendar; try calendar.check(start)
        let direction = period.count.signum()
        var left = abs(period.count), date = start
        while left > 0 {
            try budget.step(token)
            guard let next = date.addingDays(direction) else { throw CalcError.arithmetic("Working-day date range exceeded") }
            date = next
            try calendar.check(date)
            if WorkdayArithmetic.isWeekday(date), try !holidays(calendar, date.year).set.contains(date) { left -= 1 }
        }
        return .date(date)
    }

    /// Working days from `from` to `to`, both included; negative when the range is reversed.
    func between(_ from: DateOnly, _ to: DateOnly, _ calendar: WorkdayCalendar) throws -> SheetValue {
        try calendar.check(from); try calendar.check(to)
        let sign = from <= to ? 1 : -1
        let (from, to) = sign < 0 ? (to, from) : (from, to)
        if to.year - from.year >= 100 { throw CalcError.arithmetic("Working-day interval exceeds 100 calendar years") }
        let length = to.dayNumber - from.dayNumber + 1
        var count = length / 7 * 5
        for index in (length / 7 * 7)..<length {
            try budget.step(token)
            if WorkdayArithmetic.isWeekday(from.addingDays(index)!) { count += 1 }
        }
        for year in from.year...to.year {
            for date in try holidays(calendar, year).dates {
                try budget.step(token)
                if date >= from && date <= to && WorkdayArithmetic.isWeekday(date) { count -= 1 }
            }
        }
        return .number(NumericValue(Rational(sign * count)))
    }

    func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue {
        let additive = operation == "+" || operation == "-"
        if left.kind == .date && right.kind == .workdayPeriod && additive {
            let period = try right.workdays
            return try shift(try left.date, operation == "+" ? period : try period.with(count: -period.count))
        }
        if left.kind == .workdayPeriod && right.kind == .date && operation == "+" { return try shift(try right.date, try left.workdays) }
        if left.kind == .workdayPeriod && right.kind == .workdayPeriod && additive {
            let a = try left.workdays, b = try right.workdays
            if a.calendar != b.calendar { throw CalcError.arithmetic("Working-day calendars differ") }
            return .workdayPeriod(try WorkdayPeriod(a.count + (operation == "+" ? b.count : -b.count), a.calendar))
        }
        if operation == "*" && (left.kind == .number || right.kind == .number) {
            let period = left.kind == .workdayPeriod ? try left.workdays : try right.workdays
            let scale = try WorkdayArithmetic.count(left.kind == .number ? left : right)
            let product = Int64(period.count) * Int64(scale)
            if abs(product) > Int64(WorkdayPeriod.maxCount) { throw CalcError.arithmetic("Working-day count limit exceeded") }
            return .workdayPeriod(try WorkdayPeriod(Int(product), period.calendar))
        }
        throw CalcError.arithmetic("Unsupported working-day operation; working days are not elapsed time")
    }
}
