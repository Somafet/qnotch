import Foundation

final class CountdownArithmetic {
    let context: EvaluationContext, reads: ContextReads
    init(_ context: EvaluationContext, _ reads: ContextReads) { self.context = context; self.reads = reads }

    /// The next occurrence (today included) of a weekday or an annual month/day.
    func event(_ expression: CalendarEventExpression) throws -> SheetValue {
        reads.dependencies.insert(.date)
        let today = try context.requireToday()
        // DateOnly.AddDays / new DateOnly throw ArgumentOutOfRangeException in C#; nil here.
        let rangeError = CalcError.arithmetic("Calendar event range exceeded")
        if let weekday = expression.weekday {
            guard let date = today.addingDays((weekday.rawValue - today.dayOfWeek.rawValue + 7) % 7) else { throw rangeError }
            return .date(date)
        }
        // At most eight years separate Gregorian occurrences of February 29 around a non-leap century.
        for year in today.year...min(9999, today.year + 8) {
            if expression.day > DateOnly.daysInMonth(year, expression.month) { continue }
            guard let date = DateOnly(year, expression.month, expression.day) else { throw rangeError }
            if date >= today { return .date(date) }
        }
        throw CalcError.arithmetic("No calendar occurrence within years 0001 through 9999")
    }

    /// Elapsed time from the context's instant to a deadline (a local reading resolves in the local zone),
    /// clamped at zero once the deadline has passed.
    func until(_ endpoint: SheetValue) throws -> (value: SheetValue, target: ZonedMoment, expired: Bool) {
        let target = try (endpoint.kind == .zonedMoment ? endpoint : try TimestampArithmetic(context, reads).local(endpoint)).moment
        reads.dependencies.insert(.instant)
        let now = try context.requireNow()
        let ticks = target.instant.unixTicks - now.unixTicks
        let expired = ticks <= 0
        if !expired { reads.dependencies.insert(.secondTick) }
        return (.number(try TimeArithmetic.duration(max(0, ticks)).with { $0.useDaysInDuration = true }), target, expired)
    }
}
