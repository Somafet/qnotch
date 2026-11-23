using System.Numerics;

namespace Calc.Core;

internal sealed class DateArithmetic(EvaluationContext context)
{
    private static readonly Dimension Time = new(0,0,1,0,0,0,0,0);
    internal SheetValue Anchor(DateAnchorExpression expression)
    {
        var today = context.RequireToday(); var offset = expression.Offset;
        if (expression.Weekday is { } weekday)
        {
            var distance = expression.Direction > 0 ? ((int)weekday - (int)today.DayOfWeek + 7) % 7 : ((int)today.DayOfWeek - (int)weekday + 7) % 7;
            offset = (distance == 0 ? 7 : distance) * expression.Direction;
        }
        return Move(today, new(0, offset));
    }
    private static int Integer(Rational value, int limit)
    {
        if (value.Denominator != 1 || BigInteger.Abs(value.Numerator) > limit) throw new ArithmeticException("Calendar arithmetic requires bounded whole counts");
        return (int)value.Numerator;
    }
    internal static int Days(SheetValue value)
    {
        var number = value.Number;
        if (number.Unit?.Dimension != Time || number.IsPercentage || !number.IsRational || number.IsApproximate) throw new ArithmeticException("Expected an exact whole-day duration");
        return Integer(number.Exact.Rational / new Rational(86400, 1), 3660000);
    }
    private static CalendarPeriod Period(SheetValue value) => value.Kind == SheetValueKind.CalendarPeriod ? value.Period : new(0, Days(value));
    internal static SheetValue MonthPeriod(SheetValue count, int factor)
    {
        if (count.IsPercentage || count.Number.IsApproximate) throw new ArithmeticException("Calendar count must be an exact plain rational");
        return new(new CalendarPeriod(Integer(count.Scalar * new Rational(factor, 1), 120000), 0));
    }
    internal static SheetValue Shift(SheetValue date, SheetValue offset, int direction)
    {
        var period = Period(offset);
        return Move(date.Date, direction < 0 ? new(-period.Months, -period.Days) : period);
    }
    private static SheetValue Move(DateOnly date, CalendarPeriod period)
    {
        try { return new(date.AddMonths(period.Months).AddDays(period.Days)); }
        catch (ArgumentOutOfRangeException) { throw new ArithmeticException("Date range exceeded (0001-01-01 through 9999-12-31)"); }
    }
    internal static SheetValue Negate(SheetValue value)
    {
        if (value.Kind != SheetValueKind.CalendarPeriod) throw new ArithmeticException("A date cannot be negated");
        return new(new CalendarPeriod(-value.Period.Months, -value.Period.Days));
    }
    internal SheetValue Binary(string operation, SheetValue left, SheetValue right)
    {
        if (left.Kind == SheetValueKind.Date && right.Kind == SheetValueKind.Date)
        {
            if (operation != "-") throw new ArithmeticException("Only subtraction is defined between dates");
            return Duration(left.Date.DayNumber - right.Date.DayNumber, false);
        }
        if (left.Kind == SheetValueKind.Date || right.Kind == SheetValueKind.Date)
        {
            if (operation is not "+" and not "-" || right.Kind == SheetValueKind.Date && operation == "-") throw new ArithmeticException("Invalid date arithmetic");
            var date = left.Kind == SheetValueKind.Date ? left.Date : right.Date;
            var period = Period(left.Kind == SheetValueKind.Date ? right : left);
            return Move(date, operation == "-" ? new(-period.Months, -period.Days) : period);
        }
        if (operation is "+" or "-")
        {
            var a = Period(left); var b = Period(right); var sign = operation == "+" ? 1 : -1;
            return new(new CalendarPeriod(a.Months + sign * b.Months, a.Days + sign * b.Days));
        }
        if (operation == "*" || operation == "/")
        {
            var period = left.Kind == SheetValueKind.CalendarPeriod ? left.Period : right.Period;
            if (operation == "/" && left.Kind != SheetValueKind.CalendarPeriod) throw new ArithmeticException("Cannot divide by a calendar period");
            var number = left.Kind == SheetValueKind.CalendarPeriod ? right.Number : left.Number;
            if (number.IsPercentage) throw new ArithmeticException("Calendar scaling requires a plain rational");
            var scale = number.Scalar;
            var months = operation == "/" ? new Rational(period.Months, 1) / scale : new Rational(period.Months, 1) * scale;
            var days = operation == "/" ? new Rational(period.Days, 1) / scale : new Rational(period.Days, 1) * scale;
            return new(new CalendarPeriod(Integer(months, 120000), Integer(days, 3660000)));
        }
        throw new ArithmeticException("Unsupported calendar operation");
    }
    internal static SheetValue Duration(int days, bool weeks)
    {
        var unit = UnitExpression.Single(UnitCatalog.ById(weeks ? "week" : "day"));
        return new NumericValue(new ExactNumber(new Rational((long)days * 86400, 1)), unit);
    }
    internal static SheetValue Interval(string kind, SheetValue from, SheetValue to)
    {
        var start = from.Date; var end = to.Date;
        if (kind == "age")
        {
            if (end < start) throw new ArithmeticException("Age endpoint precedes the starting date");
            var years = end.Year - start.Year;
            if (start.AddYears(years) > end) years--;
            return new(new Rational(years, 1));
        }
        return Duration(end.DayNumber - start.DayNumber, kind == "weeks");
    }
}
