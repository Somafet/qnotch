using System.Globalization;
using System.Numerics;
using System.Text;

namespace Calc.Core;

/// <summary>Exact integer with an optional two's-complement word profile. Formatting never changes its value.</summary>
public sealed record IntegerValue
{
    public const int MaximumBits = 4096;
    public BigInteger Value { get; }
    public int? Width { get; }
    public bool Signed { get; }
    public int Radix { get; }
    public BigInteger Bits => Width is { } width ? Value & ((BigInteger.One << width) - 1) : Value;
    public string FullText { get; }
    public string Display => FullText.Length <= 128 ? FullText : FullText[..64] + "…" + FullText[^32..];
    public string CopyText { get; }
    internal IntegerValue(BigInteger value, int radix = 10, int? width = null, bool signed = false)
    {
        if (radix is not (2 or 8 or 10 or 16)) throw new ArithmeticException("Unsupported integer base");
        if (width is < 1 or > MaximumBits) throw new ArithmeticException("Integer width must be 1–4096 bits");
        Width = width; Signed = width is not null && signed; Radix = radix;
        if (width is { } w)
        {
            value &= (BigInteger.One << w) - 1;
            if (Signed && value >= BigInteger.One << (w - 1)) value -= BigInteger.One << w;
        }
        if (BigInteger.Abs(value).GetBitLength() > MaximumBits) throw new ArithmeticException("Integer precision limit exceeded");
        Value = value;
        FullText = Format(radix == 10 ? value : width is null ? value : Bits, radix, width);
        var target = radix switch { 2 => "bin", 8 => "oct", 16 => "hex", _ => "dec" };
        CopyText = width is not null ? "(" + Format(Bits, 16, null) + " in " + target + " " + (Signed ? "i" : "u") + width.Value.ToString(CultureInfo.InvariantCulture) + ")" :
            radix == 10 ? "(" + Format(value, 16, null) + " in dec)" : FullText;
    }
    private static string Format(BigInteger value, int radix, int? width)
    {
        if (radix == 10) return value.ToString(CultureInfo.InvariantCulture);
        var negative = value.Sign < 0; value = BigInteger.Abs(value);
        var bitsPerDigit = radix == 16 ? 4 : radix == 8 ? 3 : 1;
        var digits = new StringBuilder();
        do { digits.Append("0123456789ABCDEF"[(int)(value & (radix - 1))]); value >>= bitsPerDigit; } while (!value.IsZero);
        var count = width is { } w ? (w + bitsPerDigit - 1) / bitsPerDigit : digits.Length;
        while (digits.Length < count) digits.Append('0');
        return (negative ? "-" : "") + (radix == 16 ? "0x" : radix == 8 ? "0o" : "0b") + new string(digits.ToString().Reverse().ToArray());
    }
}
