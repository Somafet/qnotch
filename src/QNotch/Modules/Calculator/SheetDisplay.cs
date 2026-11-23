using Calc.Core;

namespace QNotch.Modules.Calculator;

/// <summary>How a result reads in the panel and in Search.</summary>
internal static class SheetDisplay
{
    /// <summary>
    /// The engine keeps repeating values as exact fractions. With automatic decimals a notepad answer reads better as a marked, rounded
    /// decimal, and copying gives what is on screen. A duration reads as days, hours and minutes. The exact value stays in the line's
    /// hover card and explanation. An explicit decimal places setting is followed as it is.
    /// </summary>
    public static (string Answer, string Copy) Present(LineResult result, SheetValue held, ResultFormat format)
    {
        var value = result.Shown ?? held;
        var exact = ResultFormatter.Format(result, format);
        if (format.DecimalPlaces is not null || value.Kind != SheetValueKind.Number || value.Number.UseCompoundDuration || !exact.Contains('/'))
            return (exact, value.CopyText);
        if (value.Number.IsDuration)
        {
            var compound = (value.Number with { UseCompoundDuration = true, UseDaysInDuration = true }).Display;
            if (!compound.Contains('/')) return (compound, compound); // 19/6 day reads as 3 d 4 h
        }
        var places = 4;
        var rounded = ResultFormatter.Format(result, format with { DecimalPlaces = places });
        if (!rounded.Any(c => c is >= '1' and <= '9'))
        {
            places = 10;
            rounded = ResultFormatter.Format(result, format with { DecimalPlaces = places });
        }
        if (rounded.Contains('/')) return (exact, value.CopyText);
        var copy = (value.Number with { DisplayDecimalPlaces = places }).Display.TrimStart('≈', ' ');
        return (rounded.StartsWith('≈') ? rounded : "≈ " + rounded, copy);
    }
}
