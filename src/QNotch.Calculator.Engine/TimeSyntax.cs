using System.Globalization;
using System.Numerics;

namespace Calc.Core;

internal static class TimeSyntax
{
    internal static int LiteralLength(string source, int start)
    {
        var cursor = start;
        while (cursor < source.Length && cursor - start < 3 && char.IsAsciiDigit(source[cursor])) cursor++;
        if (cursor == start || cursor >= source.Length || source[cursor] != ':') return 0;
        while (cursor < source.Length && cursor - start < 32 && (char.IsAsciiDigit(source[cursor]) || source[cursor] is ':' or '.')) cursor++;
        return cursor - start;
    }
    internal static bool IsMeridiem(string text) => text.Equals("am", StringComparison.OrdinalIgnoreCase) || text.Equals("pm", StringComparison.OrdinalIgnoreCase);
    internal static ClockTime Parse(string text, string? meridiem = null)
    {
        var parts = text.Split(':');
        if (parts.Length is < 2 or > 3 || parts[0].Length is < 1 or > 2 || parts[1].Length != 2 ||
            !int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var hour) ||
            !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var minute) || minute > 59) throw new FormatException("Invalid clock time");
        var ticks = 0L;
        if (parts.Length == 3)
        {
            var seconds = parts[2].Split('.');
            if (seconds.Length > 2 || seconds[0].Length != 2 || !int.TryParse(seconds[0], NumberStyles.None, CultureInfo.InvariantCulture, out var second) || second > 59)
                throw new FormatException("Invalid clock seconds");
            ticks = second * TimeSpan.TicksPerSecond;
            if (seconds.Length == 2)
            {
                if (seconds[1].Length is < 1 or > 7 || !seconds[1].All(char.IsAsciiDigit)) throw new FormatException("Clock precision is at most seven fractional second digits");
                ticks += long.Parse(seconds[1].PadRight(7, '0'), CultureInfo.InvariantCulture);
            }
        }
        if (meridiem is not null)
        {
            if (hour is < 1 or > 12) throw new FormatException("AM/PM clock hour must be from 1 to 12");
            hour = hour % 12 + (meridiem.Equals("pm", StringComparison.OrdinalIgnoreCase) ? 12 : 0);
        }
        if (hour == 24 && minute == 0 && ticks == 0) return new(TimeOnly.MinValue, 1);
        if (hour > 23) throw new FormatException("Clock hour must be from 0 to 23 (or 24:00)");
        return new(new TimeOnly(hour * TimeSpan.TicksPerHour + minute * TimeSpan.TicksPerMinute + ticks));
    }
    internal static string Duration(ExactNumber value, bool includeDays = false)
    {
        if (!value.IsRational)
        {
            var exact = "(" + value + ") s";
            if (exact.Length > 2048) throw new ArithmeticException("Output limit exceeded");
            return exact;
        }
        var seconds = value.Rational; var numerator = BigInteger.Abs(seconds.Numerator); var denominator = seconds.Denominator;
        var hours = BigInteger.DivRem(numerator, denominator * 3600, out var remainder);
        var minutes = BigInteger.DivRem(remainder, denominator * 60, out remainder);
        var pieces = new List<string>();
        if (includeDays)
        {
            var days = BigInteger.DivRem(hours, 24, out hours);
            if (!days.IsZero) pieces.Add(days.ToString(CultureInfo.InvariantCulture) + " day");
        }
        if (!hours.IsZero) pieces.Add(hours.ToString(CultureInfo.InvariantCulture) + " h");
        if (!minutes.IsZero) pieces.Add(minutes.ToString(CultureInfo.InvariantCulture) + " min");
        if (!remainder.IsZero || pieces.Count == 0)
        {
            var part = new Rational(remainder, denominator).ToString();
            pieces.Add((part.Contains('/') ? "(" + part + ")" : part) + " s");
        }
        var fractions = pieces.Any(piece => piece.Contains('/'));
        var text = string.Join(fractions ? " + " : " ", pieces);
        if (fractions && pieces.Count > 1) text = "(" + text + ")";
        if (seconds.Numerator.Sign < 0) text = "-(" + text + ")";
        if (text.Length > 2048) throw new ArithmeticException("Output limit exceeded");
        return text;
    }
}
