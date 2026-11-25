using System.Globalization;
using System.Text;

namespace Calc.Core;

/// <summary>Digit grouping and decimal separator for displayed results. Source input stays invariant.</summary>
public sealed record NumberStyle
{
    /// <summary>Narrow no-break space: a grouping space never wraps a value across lines.</summary>
    public const string Space = " ";
    public static readonly NumberStyle Plain = new("", '.');
    public static readonly IReadOnlyList<string> PresetIds = ["plain", "system", "comma", "period", "space", "apostrophe"];
    public string GroupSeparator { get; }
    public char DecimalSeparator { get; }
    public NumberStyle(string groupSeparator, char decimalSeparator)
    {
        if (decimalSeparator is not ('.' or ',')) throw new ArgumentException("Unsupported decimal separator");
        if (groupSeparator is not ("" or "," or "." or "'" or Space)) throw new ArgumentException("Unsupported group separator");
        if (groupSeparator.Length == 1 && groupSeparator[0] == decimalSeparator) throw new ArgumentException("Group and decimal separators must differ");
        GroupSeparator = groupSeparator; DecimalSeparator = decimalSeparator;
    }
    /// <summary>Resolves a stored preset. "system" reads the regional format the host supplies.</summary>
    public static NumberStyle FromId(string? id, CultureInfo regional) => id switch
    {
        null or "plain" => Plain,
        "system" => FromCulture(regional),
        "comma" => new(",", '.'),
        "period" => new(".", ','),
        "space" => new(Space, ','),
        "apostrophe" => new("'", '.'),
        _ => throw new ArgumentException("Unsupported number style")
    };
    /// <summary>Maps a culture onto the supported separators; anything else keeps the invariant form.</summary>
    public static NumberStyle FromCulture(CultureInfo culture)
    {
        var format = culture.NumberFormat;
        var decimalSeparator = format.NumberDecimalSeparator == "," ? ',' : '.';
        var group = format.NumberGroupSeparator switch
        {
            "," => ",", "." => ".", "'" or "’" => "'",
            " " or " " or " " or " " => Space,
            _ => ""
        };
        if (group.Length == 1 && group[0] == decimalSeparator) group = "";
        return new(group, decimalSeparator);
    }
    /// <summary>Compact example for settings, e.g. 1,234.56.</summary>
    public string Example => "1" + GroupSeparator + "234" + DecimalSeparator + "56";
}

/// <summary>Display-only result presentation. It never changes evaluation, copy text or saved source.</summary>
public sealed record ResultFormat(int? DecimalPlaces = null, NumberStyle? Style = null)
{
    public const int MaxDecimalPlaces = 20;
    public static readonly ResultFormat Default = new();
    public NumberStyle NumberStyle => Style ?? NumberStyle.Plain;
    public bool IsDefault => DecimalPlaces is null && NumberStyle == NumberStyle.Plain;
}

/// <summary>Presents numeric and monetary results with a display preference. Structured values (dates, times,
/// addresses, codes, text, lists, matrices, tables) keep their canonical, reusable forms.</summary>
public static class ResultFormatter
{
    public static string Format(LineResult result, ResultFormat format) =>
        result.IsDeclaration || result.Error is not null || (result.Shown ?? result.Value) is not { } value ? result.Display : Format(value, format);

    public static string Format(SheetValue value, ResultFormat format)
    {
        if (format.DecimalPlaces is < 0 or > ResultFormat.MaxDecimalPlaces) throw new ArgumentException("Unsupported decimal places");
        if (format.IsDefault) return value.Display;
        try
        {
            switch (value.Kind)
            {
                case SheetValueKind.Number:
                {
                    var number = value.Number;
                    if (number.UseCompoundDuration && number.Unit?.Dimension == TimeArithmetic.TimeDimension) return value.Display;
                    // A domain display precision (approximate conversions and roots) outranks the preference.
                    if (format.DecimalPlaces is { } places && number.DisplayDecimalPlaces is null) number = number with { DisplayDecimalPlaces = places };
                    var suffix = number.IsPercentage ? "%" : number.Unit is { } unit ? " " + unit.Symbol : "";
                    return Separate(number.Display, suffix, format.NumberStyle);
                }
                case SheetValueKind.Money:
                {
                    // Money already shows its currency's minor units; only separators change.
                    var money = value.Money;
                    return Separate(money.Display, " " + money.Currency + (money.Magnitude.Unit?.MoneySuffix() ?? ""), format.NumberStyle);
                }
                default: return value.Display;
            }
        }
        catch (ArithmeticException) { return value.Display; }
    }

    /// <summary>Rewrites separators in the magnitude only; the unit/currency suffix is left untouched.</summary>
    internal static string Separate(string text, string suffix, NumberStyle style)
    {
        if (style == NumberStyle.Plain || !text.EndsWith(suffix, StringComparison.Ordinal)) return text;
        var body = text[..^suffix.Length];
        var output = new StringBuilder(text.Length + 16);
        var i = 0;
        while (i < body.Length)
        {
            if (!char.IsAsciiDigit(body[i])) { output.Append(body[i++]); continue; }
            // Canonical displays use commas only inside constant notation groups (299,792,458).
            var start = i; var integer = new StringBuilder();
            while (i < body.Length && (char.IsAsciiDigit(body[i]) || body[i] == ',' && i + 1 < body.Length && char.IsAsciiDigit(body[i + 1])))
            { if (body[i] != ',') integer.Append(body[i]); i++; }
            string? fraction = null;
            if (i + 1 < body.Length && body[i] == '.' && char.IsAsciiDigit(body[i + 1]))
            {
                var fractionStart = ++i;
                while (i < body.Length && char.IsAsciiDigit(body[i])) i++;
                fraction = body[fractionStart..i];
            }
            var before = start > 0 ? body[start - 1] : '\0';
            var exponent = before == 'e' || (before is '-' or '+' && start > 1 && body[start - 2] == 'e');
            var radicand = start >= 5 && body.AsSpan(start - 5, 5).SequenceEqual("sqrt(");
            // A grouped numerator or denominator could read as a decimal: 1.234/7.
            var fractionPart = before == '/' || i < body.Length && body[i] == '/';
            var digits = integer.ToString();
            output.Append(exponent || radicand || fractionPart ? digits : Group(digits, style.GroupSeparator));
            if (fraction is not null) output.Append(style.DecimalSeparator).Append(fraction);
        }
        return output.Append(suffix).ToString();
    }

    private static string Group(string digits, string separator)
    {
        if (separator.Length == 0 || digits.Length < 4) return digits;
        var text = new StringBuilder(digits.Length + digits.Length / 3 * separator.Length);
        var lead = digits.Length % 3 == 0 ? 3 : digits.Length % 3;
        text.Append(digits, 0, lead);
        for (var i = lead; i < digits.Length; i += 3) text.Append(separator).Append(digits, i, 3);
        return text.ToString();
    }
}
