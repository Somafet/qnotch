using System.Globalization;
using System.Numerics;

namespace Calc.Core;

public readonly record struct Rational
{
    public BigInteger Numerator { get; }
    private readonly BigInteger denominator;
    public BigInteger Denominator => denominator.IsZero ? BigInteger.One : denominator;
    public Rational(BigInteger numerator, BigInteger denominator)
    {
        if (denominator.IsZero) throw new ArithmeticException("Division by zero");
        if (numerator.GetBitLength() > 4096 || denominator.GetBitLength() > 4096)
            throw new ArithmeticException("Precision limit exceeded");
        var gcd = BigInteger.GreatestCommonDivisor(numerator, denominator);
        Numerator = numerator / gcd * denominator.Sign;
        var reduced = BigInteger.Abs(denominator / gcd);
        this.denominator = reduced.IsOne ? BigInteger.Zero : reduced;
    }
    public static Rational Parse(string text)
    {
        if (text.Length is 0 or > 256) throw new FormatException("Invalid number");
        var parts = text.Split('.');
        var unsigned = text.TrimStart('+', '-');
        if (parts.Length > 2 || unsigned.Length == 0 || !unsigned.Any(char.IsAsciiDigit) || unsigned.Any(c => c != '.' && !char.IsAsciiDigit(c)))
            throw new FormatException("Invalid number");
        var digits = string.Concat(parts);
        return new(BigInteger.Parse(digits, CultureInfo.InvariantCulture),
            BigInteger.Pow(10, parts.Length == 2 ? parts[1].Length : 0));
    }
    public static Rational operator +(Rational a, Rational b) => new(a.Numerator * b.Denominator + b.Numerator * a.Denominator, a.Denominator * b.Denominator);
    public static Rational operator -(Rational a, Rational b) => new(a.Numerator * b.Denominator - b.Numerator * a.Denominator, a.Denominator * b.Denominator);
    public static Rational operator *(Rational a, Rational b) => new(a.Numerator * b.Numerator, a.Denominator * b.Denominator);
    public static Rational operator /(Rational a, Rational b) => new(a.Numerator * b.Denominator, a.Denominator * b.Numerator);
    public override string ToString()
    {
        // Terminating decimals are exact. Repeating values retain their rational form.
        var rest = Denominator;
        var twos = 0; var fives = 0;
        while (rest % 2 == 0) { rest /= 2; twos++; }
        while (rest % 5 == 0) { rest /= 5; fives++; }
        if (rest != 1) return $"{Numerator.ToString(CultureInfo.InvariantCulture)}/{Denominator.ToString(CultureInfo.InvariantCulture)}";
        var places = Math.Max(twos, fives);
        var scaled = BigInteger.Abs(Numerator) * BigInteger.Pow(2, places - twos) * BigInteger.Pow(5, places - fives);
        var digits = scaled.ToString(CultureInfo.InvariantCulture).PadLeft(places + 1, '0');
        var value = places == 0 ? digits : digits.Insert(digits.Length - places, ".").TrimEnd('0').TrimEnd('.');
        return Numerator.Sign < 0 ? "-" + value : value;
    }
}
