using System.Globalization;
using System.Numerics;

namespace Calc.Core;

internal static class ExactRounding
{
    internal static NumericValue Apply(RoundingKind kind, NumericValue operand, NumericValue precision, CancellationToken token, ExactArithmetic? math = null)
    {
        token.ThrowIfCancellationRequested();
        if (!operand.IsRational || !precision.IsRational) return ApplyRadical(kind, operand, precision, math ?? new(new(), token));
        if (kind == RoundingKind.Increment)
        {
            if (operand.IsPercentage != precision.IsPercentage) throw new FormatException("Rounding increment must have the same value type");
            if (precision.Scalar.Numerator.Sign <= 0) throw new ArithmeticException("Rounding increment must be positive");
            return new(ToIncrement(operand.Scalar, precision.Scalar, token), operand.IsPercentage);
        }
        var minimum = kind == RoundingKind.DecimalPlaces ? 0 : 1;
        if (precision.IsPercentage || precision.Scalar.Denominator != 1 || precision.Scalar.Numerator < minimum || precision.Scalar.Numerator > 256)
            throw new ArithmeticException($"Rounding precision must be an integer from {minimum} to 256");
        var count = (int)precision.Scalar.Numerator;
        var value = operand.IsPercentage ? operand.Scalar * new Rational(100, 1) : operand.Scalar;
        if (value.Numerator.IsZero) return operand;
        var exponent = kind == RoundingKind.DecimalPlaces ? -count : Magnitude(value, token) - count + 1;
        var scale = PowerOfTen(exponent, token);
        var rounded = ToIncrement(value, scale, token);
        return new(operand.IsPercentage ? rounded / new Rational(100, 1) : rounded, operand.IsPercentage);
    }
    private static NumericValue ApplyRadical(RoundingKind kind, NumericValue operand, NumericValue precision, ExactArithmetic math)
    {
        ExactNumber increment;
        if (kind == RoundingKind.Increment)
        {
            if (operand.IsPercentage != precision.IsPercentage) throw new FormatException("Rounding increment must have the same value type");
            if (math.Sign(precision.Exact) <= 0) throw new ArithmeticException("Rounding increment must be positive");
            increment = precision.Exact;
        }
        else
        {
            var minimum = kind == RoundingKind.DecimalPlaces ? 0 : 1;
            if (!precision.IsRational || precision.IsPercentage || precision.Scalar.Denominator != 1 || precision.Scalar.Numerator < minimum || precision.Scalar.Numerator > 256)
                throw new ArithmeticException($"Rounding precision must be an integer from {minimum} to 256");
            var count = (int)precision.Scalar.Numerator;
            var value = operand.IsPercentage ? math.Scale(operand.Exact, new Rational(100, 1)) : operand.Exact;
            if (value.IsZero) return operand;
            var magnitude = 0;
            if (kind == RoundingKind.SignificantFigures)
            {
                var absolute = math.Sign(value) < 0 ? math.Negate(value) : value;
                while (math.Sign(math.Subtract(absolute, new(PowerOfTen(magnitude, default)))) < 0) magnitude--;
                while (math.Sign(math.Subtract(absolute, new(PowerOfTen(magnitude + 1, default)))) >= 0) magnitude++;
            }
            var exponent = kind == RoundingKind.DecimalPlaces ? -count : magnitude - count + 1;
            var quantum = PowerOfTen(exponent, default);
            increment = new(operand.IsPercentage ? quantum / new Rational(100, 1) : quantum);
        }
        var quotient = math.Divide(operand.Exact, increment); var sign = math.Sign(quotient);
        if (sign < 0) quotient = math.Negate(quotient);
        var whole = math.Floor(quotient);
        var halfway = new ExactNumber(new Rational(whole * 2 + 1, 2));
        if (math.Sign(math.Subtract(quotient, halfway)) >= 0) whole++;
        return new(math.Scale(increment, new Rational(sign * whole, 1)), operand.IsPercentage);
    }
    private static Rational PowerOfTen(int exponent, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        // 10^1233 fits 4096 bits; reject before constructing a larger decimal quantum.
        if (Math.Abs(exponent) > 1233) throw new ArithmeticException("Precision limit exceeded");
        var power = BigInteger.Pow(10, Math.Abs(exponent));
        return exponent < 0 ? new(1, power) : new(power, 1);
    }
    private static int Magnitude(Rational value, CancellationToken token)
    {
        var numerator = BigInteger.Abs(value.Numerator); var denominator = value.Denominator;
        var exponent = numerator.ToString(CultureInfo.InvariantCulture).Length - denominator.ToString(CultureInfo.InvariantCulture).Length;
        token.ThrowIfCancellationRequested();
        var power = BigInteger.Pow(10, Math.Abs(exponent));
        // Compare exactly with 10^exponent: a logarithm can misclassify values close to powers of ten.
        if (exponent >= 0 ? numerator < denominator * power : numerator * power < denominator) exponent--;
        return exponent;
    }
    private static Rational ToIncrement(Rational value, Rational increment, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        // Both inputs have <=4096-bit components, bounding these temporary integer products to 8192 bits.
        var numerator = BigInteger.Abs(value.Numerator) * increment.Denominator;
        var denominator = value.Denominator * increment.Numerator;
        var whole = BigInteger.DivRem(numerator, denominator, out var remainder);
        if (remainder * 2 >= denominator) whole++;
        token.ThrowIfCancellationRequested();
        // Cancel before multiplication so a representable answer is not rejected for an unreduced product.
        var common = BigInteger.GreatestCommonDivisor(whole, increment.Denominator);
        return new(value.Numerator.Sign * (whole / common) * increment.Numerator, increment.Denominator / common);
    }
}
