using System.Numerics;

namespace Calc.Core;

internal static class TimeArithmetic
{
    internal static readonly Dimension TimeDimension = new(0, 0, 1, 0, 0, 0, 0, 0);
    internal const string WorkedKind = "workedTime";
    internal static SheetValue Range(SheetValue start, SheetValue end)
    {
        var a = start.Time; var b = end.Time; var ticks = b.TotalTicks - a.TotalTicks;
        if (b.DayOffset == a.DayOffset && ticks < 0) ticks += TimeSpan.TicksPerDay;
        if (ticks < 0) throw new ArithmeticException("Interval ends before its explicit starting day");
        return Duration(ticks, true);
    }
    internal static NumericValue Duration(long ticks, bool worked = false)
        => new(new ExactNumber(new Rational(ticks, TimeSpan.TicksPerSecond)), UnitExpression.Single(UnitCatalog.ById("s")))
        { UseCompoundDuration = true, QuantityKind = worked ? WorkedKind : "" };
    internal static BigInteger Ticks(SheetValue value)
    {
        var number = value.Number;
        if (number.Unit?.Dimension != TimeDimension || !number.IsRational || number.IsPercentage || number.IsApproximate) throw new ArithmeticException("Clock shifts require an exact rational time duration");
        var ticks = number.Exact.Rational * new Rational(TimeSpan.TicksPerSecond, 1);
        if (ticks.Denominator != 1) throw new ArithmeticException("Clock shift must be an exact multiple of 100 nanoseconds");
        return ticks.Numerator;
    }
    internal static SheetValue Binary(string operation, SheetValue left, SheetValue right)
    {
        if (left.Kind == SheetValueKind.Time && right.Kind == SheetValueKind.Time)
        {
            if (operation != "-") throw new ArithmeticException("Only subtraction is defined between clock readings; use an explicit range for overnight work");
            return Duration(left.Time.TotalTicks - right.Time.TotalTicks);
        }
        if (operation is not "+" and not "-" || operation == "-" && left.Kind != SheetValueKind.Time)
            throw new ArithmeticException("Invalid clock arithmetic");
        var clock = left.Kind == SheetValueKind.Time ? left.Time : right.Time;
        var ticks = Ticks(left.Kind == SheetValueKind.Time ? right : left);
        return new(ClockTime.FromTicks(clock.TotalTicks + (operation == "-" ? -ticks : ticks)));
    }
}
