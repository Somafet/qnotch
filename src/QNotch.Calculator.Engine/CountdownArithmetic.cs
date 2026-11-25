namespace Calc.Core;

internal sealed class CountdownArithmetic(EvaluationContext context, ContextReads reads)
{
    internal SheetValue Event(CalendarEventExpression expression)
    {
        reads.Dependencies |= ContextDependency.Date;
        var today = context.RequireToday();
        try
        {
            if (expression.Weekday is { } weekday) return new(today.AddDays(((int)weekday - (int)today.DayOfWeek + 7) % 7));
            // At most eight years separate Gregorian occurrences of February 29 around a non-leap century.
            for (var year = today.Year; year <= Math.Min(9999, today.Year + 8); year++)
            {
                if (expression.Day > DateTime.DaysInMonth(year, expression.Month)) continue;
                var date = new DateOnly(year, expression.Month, expression.Day);
                if (date >= today) return new(date);
            }
        }
        catch (ArgumentOutOfRangeException) { throw new ArithmeticException("Calendar event range exceeded"); }
        throw new ArithmeticException("No calendar occurrence within years 0001 through 9999");
    }
    internal SheetValue Until(SheetValue endpoint, out ZonedMoment target, out bool expired)
    {
        target = (endpoint.Kind == SheetValueKind.ZonedMoment ? endpoint : new TimestampArithmetic(context, reads).Local(endpoint)).Moment;
        reads.Dependencies |= ContextDependency.Instant;
        var now = context.RequireNow(); var ticks = target.Instant.ToUnixTimeTicks() - now.ToUnixTimeTicks();
        expired = ticks <= 0;
        if (!expired) reads.Dependencies |= ContextDependency.SecondTick;
        return TimeArithmetic.Duration(Math.Max(0, ticks)) with { UseDaysInDuration = true };
    }
}
