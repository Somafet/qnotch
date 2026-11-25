using System.Numerics;

namespace Calc.Core;

internal sealed class WorkdayArithmetic(ExecutionBudget budget, CancellationToken token)
{
    private readonly Dictionary<(WorkdayCalendar, int), HashSet<DateOnly>> years = [];
    private HashSet<DateOnly> Holidays(WorkdayCalendar calendar, int year)
    {
        if (years.TryGetValue((calendar, year), out var found)) return found;
        if (years.Count >= 100) throw new ArithmeticException("Working-day calendar cache limit exceeded");
        budget.Step(token);
        var holidays = calendar.Holidays(year);
        foreach (var _ in holidays) budget.Step(token);
        return years[(calendar, year)] = holidays.Select(holiday => holiday.Date).ToHashSet();
    }
    internal static int Count(SheetValue value)
    {
        var number = value.Number;
        if (number.Unit is not null || number.IsPercentage || !number.IsRational || number.IsApproximate || number.Scalar.Denominator != 1 || BigInteger.Abs(number.Scalar.Numerator) > WorkdayPeriod.MaxCount)
            throw new ArithmeticException("Working days require a plain whole count from -10,000 to 10,000");
        return (int)number.Scalar.Numerator;
    }
    internal SheetValue Shift(DateOnly start, WorkdayPeriod period)
    {
        var calendar = period.Calendar; calendar.Check(start);
        var direction = Math.Sign(period.Count); var left = Math.Abs(period.Count); var date = start;
        try
        {
            while (left > 0)
            {
                budget.Step(token); date = date.AddDays(direction); calendar.Check(date);
                if (date.DayOfWeek is not DayOfWeek.Saturday and not DayOfWeek.Sunday && !Holidays(calendar, date.Year).Contains(date)) left--;
            }
        }
        catch (ArgumentOutOfRangeException) { throw new ArithmeticException("Working-day date range exceeded"); }
        return new(date);
    }
    internal SheetValue Between(DateOnly from, DateOnly to, WorkdayCalendar calendar)
    {
        calendar.Check(from); calendar.Check(to);
        var sign = from <= to ? 1 : -1;
        if (sign < 0) (from, to) = (to, from);
        if (to.Year - from.Year >= 100) throw new ArithmeticException("Working-day interval exceeds 100 calendar years");
        var length = to.DayNumber - from.DayNumber + 1; var count = length / 7 * 5;
        for (var index = length / 7 * 7; index < length; index++)
        { budget.Step(token); if (from.AddDays(index).DayOfWeek is not DayOfWeek.Saturday and not DayOfWeek.Sunday) count++; }
        for (var year = from.Year; year <= to.Year; year++)
            foreach (var date in Holidays(calendar, year))
            { budget.Step(token); if (date >= from && date <= to && date.DayOfWeek is not DayOfWeek.Saturday and not DayOfWeek.Sunday) count--; }
        return new(new Rational(sign * count, 1));
    }
    internal SheetValue Binary(string operation, SheetValue left, SheetValue right)
    {
        if (left.Kind == SheetValueKind.Date && right.Kind == SheetValueKind.WorkdayPeriod && operation is "+" or "-")
            return Shift(left.Date, operation == "+" ? right.Workdays : right.Workdays with { Count = -right.Workdays.Count });
        if (left.Kind == SheetValueKind.WorkdayPeriod && right.Kind == SheetValueKind.Date && operation == "+") return Shift(right.Date, left.Workdays);
        if (left.Kind == SheetValueKind.WorkdayPeriod && right.Kind == SheetValueKind.WorkdayPeriod && operation is "+" or "-")
        {
            if (!left.Workdays.Calendar.Equals(right.Workdays.Calendar)) throw new ArithmeticException("Working-day calendars differ");
            return new(new WorkdayPeriod(left.Workdays.Count + (operation == "+" ? right.Workdays.Count : -right.Workdays.Count), left.Workdays.Calendar));
        }
        if (operation == "*" && (left.Kind == SheetValueKind.Number || right.Kind == SheetValueKind.Number))
        {
            var period = left.Kind == SheetValueKind.WorkdayPeriod ? left.Workdays : right.Workdays;
            var scale = Count(left.Kind == SheetValueKind.Number ? left : right);
            var product = (long)period.Count * scale;
            if (Math.Abs(product) > WorkdayPeriod.MaxCount) throw new ArithmeticException("Working-day count limit exceeded");
            return new(new WorkdayPeriod((int)product, period.Calendar));
        }
        throw new ArithmeticException("Unsupported working-day operation; working days are not elapsed time");
    }
}
