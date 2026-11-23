using System.Globalization;
using System.Numerics;
using System.Text;

namespace Calc.Core;

/// <summary>An immutable exact real sum of rational multiples of square-free integer roots.</summary>
public readonly struct ExactNumber : IEquatable<ExactNumber>
{
    internal readonly record struct Term(BigInteger Radicand, Rational Coefficient);
    private readonly Rational rational;
    private readonly Term[]? radicals;
    internal ReadOnlySpan<Term> Radicals => radicals;
    internal Rational Constant => rational;
    public bool IsRational => radicals is null;
    public Rational Rational => IsRational ? rational : throw new ArithmeticException("Exact rational value required");
    internal bool IsZero => IsRational && rational.Numerator.IsZero;
    public ExactNumber(Rational value) { rational = value; radicals = null; }
    internal ExactNumber(SortedDictionary<BigInteger, Rational> terms)
    {
        rational = terms.GetValueOrDefault(BigInteger.One);
        radicals = terms.Where(pair => pair.Key != 1 && !pair.Value.Numerator.IsZero).Select(pair => new Term(pair.Key, pair.Value)).ToArray();
        if (radicals.Length > 32) throw new ArithmeticException("Radical term limit exceeded");
        if (radicals.Length == 0) radicals = null;
    }
    internal IEnumerable<Term> Terms()
    {
        if (!rational.Numerator.IsZero) yield return new(1, rational);
        if (radicals is not null) foreach (var term in radicals) yield return term;
    }
    public bool Equals(ExactNumber other) => rational == other.rational && Radicals.SequenceEqual(other.Radicals);
    public override bool Equals(object? obj) => obj is ExactNumber other && Equals(other);
    public override int GetHashCode()
    {
        var hash = new HashCode(); hash.Add(rational);
        foreach (var term in Radicals) hash.Add(term);
        return hash.ToHashCode();
    }
    public static bool operator ==(ExactNumber left, ExactNumber right) => left.Equals(right);
    public static bool operator !=(ExactNumber left, ExactNumber right) => !left.Equals(right);
    public override string ToString()
    {
        if (IsRational) return rational.ToString();
        var text = new StringBuilder();
        foreach (var term in Terms())
        {
            var negative = term.Coefficient.Numerator.Sign < 0;
            text.Append(text.Length == 0 ? negative ? "-" : "" : negative ? " - " : " + ");
            var coefficient = new Rational(BigInteger.Abs(term.Coefficient.Numerator), term.Coefficient.Denominator);
            if (term.Radicand == 1) text.Append(coefficient);
            else
            {
                if (coefficient != new Rational(1, 1))
                {
                    var value = coefficient.ToString();
                    text.Append(value.Contains('/') ? "(" + value + ")" : value).Append('*');
                }
                text.Append("sqrt(").Append(term.Radicand.ToString(CultureInfo.InvariantCulture)).Append(')');
            }
            if (text.Length > 2048) throw new ArithmeticException("Output limit exceeded");
        }
        return text.ToString();
    }
}
