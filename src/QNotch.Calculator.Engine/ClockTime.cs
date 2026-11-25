using System.Globalization;
using System.Numerics;

namespace Calc.Core;

/// <summary>A clock reading with an explicit relative day, independent of timezone/instant.</summary>
public readonly record struct ClockTime(TimeOnly Time, int DayOffset = 0)
{
    internal long TotalTicks => (long)DayOffset * TimeSpan.TicksPerDay + Time.Ticks;
    internal ClockTime Checked()
    {
        if (Math.Abs((long)DayOffset) > 3660000) throw new ArithmeticException("Clock day-offset limit exceeded");
        return this;
    }
    internal static ClockTime FromTicks(BigInteger ticks)
    {
        var day = BigInteger.DivRem(ticks, TimeSpan.TicksPerDay, out var remainder);
        if (remainder.Sign < 0) { day--; remainder += TimeSpan.TicksPerDay; }
        if (BigInteger.Abs(day) > 3660000) throw new ArithmeticException("Clock day-offset limit exceeded");
        return new(new TimeOnly((long)remainder), (int)day);
    }
    public override string ToString()
    {
        var text = Time.ToString(Time.Ticks % TimeSpan.TicksPerMinute == 0 ? "HH:mm" : "HH:mm:ss.fffffff", CultureInfo.InvariantCulture);
        if (text.Contains('.')) text = text.TrimEnd('0').TrimEnd('.');
        return DayOffset == 0 ? text : "(" + text + (DayOffset < 0 ? " - " : " + ") + Math.Abs(DayOffset).ToString(CultureInfo.InvariantCulture) + " day)";
    }
}
