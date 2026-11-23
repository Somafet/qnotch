namespace Calc.Core;

/// <summary>Immutable complex number with a nonzero imaginary part. A zero imaginary part is always a real number instead.</summary>
public sealed record ComplexValue
{
    private const int MaxOutput = 2048;
    public ExactNumber Real { get; }
    public ExactNumber Imaginary { get; }
    public bool IsApproximate { get; }
    internal ComplexValue(ExactNumber real, ExactNumber imaginary, bool isApproximate = false)
    {
        if (imaginary.IsZero) throw new ArithmeticException("A complex value requires a nonzero imaginary part");
        Real = real; Imaginary = imaginary; IsApproximate = isApproximate;
    }
    public string Display => (IsApproximate ? "≈ " : "") + Text(IsApproximate);
    /// <summary>Complete parts without the marker or display rounding; pasting it back reproduces the value.</summary>
    public string CopyText => Text(false);
    private string Text(bool rounded)
    {
        var math = new ExactArithmetic(new(), default);
        string Part(ExactNumber value) => rounded ? FormulaNumbers.FromDouble(FormulaNumbers.ToDouble(value)).ToString() : value.ToString();
        var negative = math.Sign(Imaginary) < 0;
        var size = Part(negative ? math.Negate(Imaginary) : Imaginary);
        var imaginary = size == "1" ? "i" : size.All(c => char.IsAsciiDigit(c) || c == '.') ? size + "i" :
            size.Contains(' ') || size.Contains('/') && !size.Contains("sqrt", StringComparison.Ordinal) ? "(" + size + ")*i" : size + "*i";
        var text = Real.IsZero ? (negative ? "-" : "") + imaginary : Part(Real) + (negative ? " - " : " + ") + imaginary;
        return text.Length <= MaxOutput ? text : throw new ArithmeticException("Output limit exceeded");
    }
    public override string ToString() => Display;
}
