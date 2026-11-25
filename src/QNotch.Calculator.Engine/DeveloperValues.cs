using System.Globalization;
using System.Numerics;
using System.Text;

namespace Calc.Core;

public enum ColourPresentation { Hex, Rgb, Hsl }
public sealed record ColourValue
{
    public Rational Red { get; }
    public Rational Green { get; }
    public Rational Blue { get; }
    public Rational Alpha { get; }
    public ColourPresentation Presentation { get; }
    public Rational Hue { get; }
    public Rational Saturation { get; }
    public Rational Lightness { get; }
    public bool Achromatic => Saturation.Numerator.IsZero;
    public bool HexQuantized => new[] { Red, Green, Blue, Alpha }.Any(v => (v * new Rational(255, 1)).Denominator != 1);
    public string Hex => "#" + string.Concat(new[] { Red, Green, Blue }.Select(v => Byte(v).ToString("X2", CultureInfo.InvariantCulture))) + (Alpha == new Rational(1, 1) ? "" : Byte(Alpha).ToString("X2", CultureInfo.InvariantCulture));
    public string Display => Presentation switch
    {
        ColourPresentation.Rgb => (Alpha == new Rational(1, 1) ? "rgb(" : "rgba(") + string.Join(", ", new[] { Red, Green, Blue }.Select(v => Shown(v * new Rational(255, 1)))) + (Alpha == new Rational(1, 1) ? "" : ", " + Shown(Alpha)) + ")",
        ColourPresentation.Hsl => (Alpha == new Rational(1, 1) ? "hsl(" : "hsla(") + Shown(Hue) + ", " + Shown(Saturation * new Rational(100, 1)) + "%, " + Shown(Lightness * new Rational(100, 1)) + "%" + (Alpha == new Rational(1, 1) ? "" : ", " + Shown(Alpha)) + ")",
        _ => (HexQuantized ? "≈ " : "") + Hex
    };
    public string CopyText
    {
        get
        {
            var source = "rgb(" + string.Join(',', new[] { Red, Green, Blue }.Select(v => DeveloperSource.Fraction(v * new Rational(255, 1)))) + "," + DeveloperSource.Fraction(Alpha) + ")";
            return Presentation == ColourPresentation.Hsl ? "hsl(" + source + ")" : Presentation == ColourPresentation.Hex ? "colourhex(" + source + ")" : source;
        }
    }
    public string Details => "sRGB encoded channels (not linear light): R=" + Red + ", G=" + Green + ", B=" + Blue + "; alpha=" + Alpha +
        "\nHSL: H=" + Hue + " degrees, S=" + Saturation + ", L=" + Lightness + (Achromatic ? "; achromatic hue rendered as zero by convention" : "") +
        "\n8-bit hex: " + Hex + (HexQuantized ? "; nearest-byte presentation, exact stored channels retained" : "; exact byte channels") +
        "\nFour-decimal presentation does not replace stored fractions; no profile, gamut mapping or alpha compositing inferred";
    internal ColourValue(Rational red, Rational green, Rational blue, Rational alpha, ColourPresentation presentation)
    {
        foreach (var v in new[] { red, green, blue, alpha }) if (v.Numerator < 0 || v.Numerator > v.Denominator) throw new ArithmeticException("Colour channels and alpha must be in range");
        Red = red; Green = green; Blue = blue; Alpha = alpha; Presentation = presentation;
        var max = new[] { red, green, blue }.MaxBy(v => v, DeveloperSource.Comparer); var min = new[] { red, green, blue }.MinBy(v => v, DeveloperSource.Comparer);
        var delta = max - min; Lightness = (max + min) / new Rational(2, 1);
        if (delta.Numerator.IsZero) { Hue = default; Saturation = default; }
        else
        {
            Saturation = delta / (new Rational(1, 1) - DeveloperSource.Abs(new Rational(2, 1) * Lightness - new Rational(1, 1)));
            var sector = max == red ? (green - blue) / delta : max == green ? (blue - red) / delta + new Rational(2, 1) : (red - green) / delta + new Rational(4, 1);
            Hue = DeveloperSource.Mod(sector * new Rational(60, 1), 360);
        }
    }
    internal ColourValue WithPresentation(ColourPresentation style) => new(Red, Green, Blue, Alpha, style);
    private static int Byte(Rational value) => (int)((value.Numerator * 510 + value.Denominator) / (2 * value.Denominator));
    private static string Shown(Rational value) => new NumericValue(value) { DisplayDecimalPlaces = 4 }.Display;
}

public sealed record PermissionValue
{
    public int Bits { get; }
    public bool ShowOctal { get; }
    public string Octal => Convert.ToString(Bits, 8).PadLeft(3, '0');
    public string Symbolic { get; }
    public string Display => ShowOctal ? Octal : Symbolic;
    public string CopyText => ShowOctal ? "modeoctal(chmod(\"" + Octal + "\"))" : "chmod(\"" + Octal + "\")";
    public string Details => "Unix permission bits: 0o" + Octal + " (" + Bits.ToString(CultureInfo.InvariantCulture) + " decimal); " + Symbolic +
        "\nOwner: " + Symbolic[..3] + "; group: " + Symbolic[3..6] + "; other: " + Symbolic[6..] +
        "; setuid=" + ((Bits & 2048) != 0) + ", setgid=" + ((Bits & 1024) != 0) + ", sticky=" + ((Bits & 512) != 0) +
        "\nMode-bit conversion only; no filesystem, Windows ACL, umask, ownership or effective-access change";
    internal PermissionValue(int bits, bool showOctal = false)
    {
        if (bits is < 0 or > 4095) throw new ArithmeticException("Permission mode must fit 0000–7777 octal");
        Bits = bits; ShowOctal = showOctal; var chars = "---------".ToCharArray();
        for (var group = 0; group < 3; group++)
        {
            var n = (bits >> (6 - group * 3)) & 7;
            if ((n & 4) != 0) chars[group * 3] = 'r'; if ((n & 2) != 0) chars[group * 3 + 1] = 'w';
            chars[group * 3 + 2] = (n & 1) != 0 ? 'x' : '-';
        }
        foreach (var (flag, index, lower, upper) in new[] { (2048, 2, 's', 'S'), (1024, 5, 's', 'S'), (512, 8, 't', 'T') })
            if ((bits & flag) != 0) chars[index] = chars[index] == 'x' ? lower : upper;
        Symbolic = new string(chars);
    }
}

public sealed record AspectValue
{
    public Rational Ratio { get; }
    public string FullText => Ratio.Numerator.ToString(CultureInfo.InvariantCulture) + ":" + Ratio.Denominator.ToString(CultureInfo.InvariantCulture);
    public string Display => FullText.Length <= 96 ? FullText : FullText[..64] + "…" + FullText[^24..];
    public string CopyText => "aspect(" + DeveloperSource.Integer(Ratio.Numerator) + "," + DeveloperSource.Integer(Ratio.Denominator) + ")";
    public string Details => "Reduced width:height = " + FullText + "; exact ratio " + Ratio + "\nPositive proportional dimensions; no pixel rounding, resize target or physical display geometry inferred";
    internal AspectValue(Rational ratio) { if (ratio.Numerator <= 0) throw new ArithmeticException("Aspect dimensions must be positive"); Ratio = ratio; }
}

public sealed class UnicodeValue : IEquatable<UnicodeValue>
{
    public IReadOnlyList<int> Scalars { get; }
    public bool ShowGlyph { get; }
    public string Text { get; }
    public string Labels => string.Join(' ', Scalars.Select(v => "U+" + v.ToString("X4", CultureInfo.InvariantCulture)));
    public string Display { get; }
    public string CopyText => ShowGlyph ? "codepoint(" + Scalars[0].ToString(CultureInfo.InvariantCulture) + ")" : "unicode(" + new TextValue(Text).ExpressionText + ")";
    public string Details => "Unicode scalar sequence: " + Labels + "\nUTF-8: " + Convert.ToHexStringLower(Encoding.UTF8.GetBytes(Text)) +
        "\nScalars are not grapheme clusters; no normalization, character-name catalog or glyph support inferred";
    internal UnicodeValue(IEnumerable<int> scalars, bool showGlyph)
    {
        var values = scalars.ToArray(); if (values.Length is < 1 or > 256 || values.Any(v => !Rune.IsValid(v))) throw new ArithmeticException("Expected 1–256 Unicode scalar values");
        if (showGlyph && values.Length != 1) throw new ArithmeticException("Glyph form requires one scalar");
        Scalars = Array.AsReadOnly(values); ShowGlyph = showGlyph; Text = string.Concat(values.Select(v => new Rune(v).ToString()));
        var labels = Labels; Display = showGlyph ? new TextValue(Text).Display + " " + labels : labels.Length <= 96 ? labels : labels[..64] + "…" + labels[^24..];
    }
    public bool Equals(UnicodeValue? other) => other is not null && ShowGlyph == other.ShowGlyph && Scalars.SequenceEqual(other.Scalars);
    public override bool Equals(object? obj) => obj is UnicodeValue other && Equals(other);
    public override int GetHashCode() { var hash = new HashCode(); hash.Add(ShowGlyph); foreach (var n in Scalars) hash.Add(n); return hash.ToHashCode(); }
}

internal static class DeveloperSource
{
    internal static readonly IComparer<Rational> Comparer = System.Collections.Generic.Comparer<Rational>.Create((a,b) => (a.Numerator*b.Denominator).CompareTo(b.Numerator*a.Denominator));
    internal static Rational Abs(Rational v) => new(BigInteger.Abs(v.Numerator), v.Denominator);
    internal static Rational Mod(Rational v, int divisor) { var denominator = v.Denominator * divisor; var n = v.Numerator % denominator; return new(n < 0 ? n + denominator : n, v.Denominator); }
    internal static string Integer(BigInteger n) => n.Sign < 0 ? "(-" + Integer(BigInteger.Abs(n)) + ")" : "0x" + n.ToString("X", CultureInfo.InvariantCulture);
    internal static string Fraction(Rational r) => r.Denominator == 1 ? Integer(r.Numerator) : "(" + Integer(r.Numerator) + "/" + Integer(r.Denominator) + ")";
}
