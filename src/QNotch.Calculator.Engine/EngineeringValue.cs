using System.Globalization;
using System.Numerics;

namespace Calc.Core;

/// <summary>Six-significant-figure engineering presentation; the underlying numeric value is unchanged.</summary>
public sealed class EngineeringValue : IEquatable<EngineeringValue>
{
    public NumericValue Original { get; }
    public string Display { get; }
    public string CopyText { get; }
    internal EngineeringValue(NumericValue original, ExactArithmetic math, ExecutionBudget budget, CancellationToken token)
    {
        if (original.Unit?.IsTemperaturePoint == true) throw new ArithmeticException("Engineering notation requires a linear quantity, not an absolute temperature point");
        Original = original; var quantities = new QuantityArithmetic(math);
        var rounded = quantities.Round(RoundingKind.SignificantFigures, original, new(new Rational(6, 1)), token);
        var unit = original.Unit;
        if (unit is not null && unit.Key.EndsWith(":1", StringComparison.Ordinal) && !unit.Key.Contains(';') && PowerOfTen(unit.Factor))
        {
            foreach (var candidate in UnitCatalog.Units)
            {
                budget.Step(token);
                if (candidate.Dimension != unit.Dimension || candidate.IsTemperaturePoint || candidate.Kind != unit.Kind || !PowerOfTen(candidate.Factor)) continue;
                var magnitude = rounded.Exact.Rational / candidate.Factor;
                if (magnitude.Numerator.Sign < 0) magnitude *= new Rational(-1, 1);
                if ((magnitude - new Rational(1, 1)).Numerator.Sign >= 0 && (magnitude - new Rational(1000, 1)).Numerator.Sign < 0)
                { unit = UnitExpression.Single(candidate); break; }
            }
        }
        var shown = unit is null ? rounded.Exact.Rational : quantities.DisplayMagnitude(rounded with { Unit = unit }).Rational;
        if (original.IsPercentage) shown *= new Rational(100, 1);
        var exponent = 0;
        if (shown.Numerator.Sign != 0)
        {
            var abs = BigInteger.Abs(shown.Numerator); var denominator = shown.Denominator;
            var decimalExponent = abs.ToString(CultureInfo.InvariantCulture).Length - denominator.ToString(CultureInfo.InvariantCulture).Length;
            if (decimalExponent >= 0 ? abs < denominator * BigInteger.Pow(10, decimalExponent) : abs * BigInteger.Pow(10, -decimalExponent) < denominator) decimalExponent--;
            exponent = (decimalExponent >= 0 ? decimalExponent / 3 : (decimalExponent - 2) / 3) * 3;
        }
        var coefficient = exponent >= 0 ? shown / new Rational(BigInteger.Pow(10, exponent), 1) : shown * new Rational(BigInteger.Pow(10, -exponent), 1);
        static string Superscript(int value) => string.Concat(value.ToString(CultureInfo.InvariantCulture).Select(c => c == '-' ? '⁻' : "⁰¹²³⁴⁵⁶⁷⁸⁹"[c - '0']));
        Display = (original.IsApproximate ? "≈ " : "") + coefficient + (exponent == 0 ? "" : " × 10" + Superscript(exponent)) + (original.IsPercentage ? "%" : unit is null ? "" : " " + unit.Symbol);
        if (Display.Length > 2048) throw new ArithmeticException("Engineering output limit exceeded");
        var exact = original.Unit is null ? original.Exact : quantities.DisplayMagnitude(original);
        var source = ExactSource(exact);
        if (original.IsPercentage) source = "(" + source + "*100)%";
        else if (original.Unit is not null) source = "(" + source + ") " + original.Unit.Symbol;
        CopyText = "engineering(" + source + (original.IsApproximate ? ",1" : "") + ")";
    }
    private static bool PowerOfTen(Rational value)
    {
        var n = value.Numerator; var d = value.Denominator;
        while (n > 1 && n % 10 == 0) n /= 10;
        while (d > 1 && d % 10 == 0) d /= 10;
        return n == 1 && d == 1;
    }
    private static string IntegerSource(BigInteger value)
    {
        if (value.Sign < 0) return "(-" + IntegerSource(BigInteger.Abs(value)) + ")";
        var digits = value.ToString(CultureInfo.InvariantCulture);
        if (digits.Length <= 200) return digits;
        var result = digits[..200];
        for (var offset = 200; offset < digits.Length; offset += 200)
        { var chunk = digits.Substring(offset, Math.Min(200, digits.Length - offset)); result = "(" + result + "*10^" + chunk.Length + "+" + BigInteger.Parse(chunk, CultureInfo.InvariantCulture) + ")"; }
        return result;
    }
    private static string ExactSource(ExactNumber number)
    {
        string RationalSource(Rational value) => value.Denominator == 1 ? IntegerSource(value.Numerator) : "(" + IntegerSource(value.Numerator) + "/" + IntegerSource(value.Denominator) + ")";
        if (number.IsRational) return RationalSource(number.Rational);
        return "(" + string.Join('+', number.Terms().Select(term => RationalSource(term.Coefficient) + (term.Radicand == 1 ? "" : "*sqrt(" + IntegerSource(term.Radicand) + ")"))) + ")";
    }
    public bool Equals(EngineeringValue? other) => ReferenceEquals(this, other) || other is not null && Original == other.Original;
    public override bool Equals(object? obj) => obj is EngineeringValue other && Equals(other);
    public override int GetHashCode() => Original.GetHashCode();
    public override string ToString() => Display;
}
