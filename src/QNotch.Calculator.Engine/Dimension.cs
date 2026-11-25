namespace Calc.Core;

/// <summary>SI base dimensions plus information; exponents are bounded independently of magnitude.</summary>
public readonly record struct Dimension(int Length, int Mass, int Time, int Current, int Temperature, int Amount, int LuminousIntensity, int Information)
{
    internal int[] Components => [Length, Mass, Time, Current, Temperature, Amount, LuminousIntensity, Information];
    internal static Dimension From(IReadOnlyList<int> values)
    {
        if (values.Count != 8 || values.Any(value => Math.Abs((long)value) > 16)) throw new ArithmeticException("Dimension exponent limit exceeded");
        return new(values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7]);
    }
    internal Dimension Combine(Dimension other, int sign) => From(Components.Zip(other.Components, (a, b) => a + sign * b).ToArray());
    internal Dimension Power(Rational exponent)
    {
        var values = Components.Select(value => new Rational(value, 1) * exponent).ToArray();
        if (values.Any(value => value.Denominator != 1 || System.Numerics.BigInteger.Abs(value.Numerator) > 16))
            throw new ArithmeticException("Quantity power must have bounded integer dimensions");
        return From(values.Select(value => (int)value.Numerator).ToArray());
    }
}
