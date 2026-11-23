using System.Numerics;

namespace Calc.Core;

/// <summary>Bounded multiquadratic arithmetic. No floating point, probabilistic factoring or global caches.</summary>
internal sealed class ExactArithmetic(ExecutionBudget budget, CancellationToken token)
{
    internal static readonly ExactNumber One = new(new Rational(1, 1));
    private const string NegativeRoot = "A negative quantity has no real square root, and complex values do not carry units or money";
    private void Step() => budget.Step(token);
    internal ExactNumber Add(ExactNumber a, ExactNumber b)
    {
        if (a.IsRational && b.IsRational) return new(a.Rational + b.Rational);
        var terms = new SortedDictionary<BigInteger, Rational>();
        foreach (var term in a.Terms().Concat(b.Terms())) { Step(); Accumulate(terms, term.Radicand, term.Coefficient); }
        return new(terms);
    }
    internal ExactNumber Negate(ExactNumber value) => Scale(value, new Rational(-1, 1));
    internal ExactNumber Subtract(ExactNumber a, ExactNumber b) => Add(a, Negate(b));
    internal ExactNumber Scale(ExactNumber value, Rational factor)
    {
        if (value.IsRational) return new(value.Rational * factor);
        var terms = new SortedDictionary<BigInteger, Rational>();
        foreach (var term in value.Terms()) { Step(); Accumulate(terms, term.Radicand, term.Coefficient * factor); }
        return new(terms);
    }
    internal ExactNumber Multiply(ExactNumber a, ExactNumber b)
    {
        if (a.IsRational) return Scale(b, a.Rational);
        if (b.IsRational) return Scale(a, b.Rational);
        var terms = new SortedDictionary<BigInteger, Rational>();
        foreach (var x in a.Terms()) foreach (var y in b.Terms())
        {
            Step();
            var common = BigInteger.GreatestCommonDivisor(x.Radicand, y.Radicand);
            var radicand = (x.Radicand / common) * (y.Radicand / common);
            if (radicand.GetBitLength() > 4096) throw new ArithmeticException("Precision limit exceeded");
            Accumulate(terms, radicand, x.Coefficient * y.Coefficient * new Rational(common, 1));
        }
        return new(terms);
    }
    private static void Accumulate(SortedDictionary<BigInteger, Rational> terms, BigInteger radicand, Rational coefficient)
    {
        var sum = terms.GetValueOrDefault(radicand) + coefficient;
        if (sum.Numerator.IsZero) terms.Remove(radicand); else terms[radicand] = sum;
        if (terms.Count > 33) throw new ArithmeticException("Radical term limit exceeded");
    }
    internal ExactNumber Divide(ExactNumber a, ExactNumber b)
    {
        if (b.IsRational) return Scale(a, new Rational(1, 1) / b.Rational);
        // Each conjugation removes a prime generator from the denominator's field.
        for (var pass = 0; !b.IsRational; pass++)
        {
            Step();
            if (pass >= 16) throw new ArithmeticException("Radical rationalization limit exceeded");
            var single = b.Radicals.Length == 1;
            var prime = single ? BigInteger.One : SmallestFactor(b.Radicals[0].Radicand);
            var conjugate = new SortedDictionary<BigInteger, Rational>();
            foreach (var term in b.Terms())
                conjugate[term.Radicand] = term.Radicand != 1 && (single || term.Radicand % prime == 0)
                    ? new Rational(-1, 1) * term.Coefficient : term.Coefficient;
            var c = new ExactNumber(conjugate);
            a = Multiply(a, c); b = Multiply(b, c);
        }
        return Scale(a, new Rational(1, 1) / b.Rational);
    }
    private BigInteger SmallestFactor(BigInteger value)
    {
        for (var divisor = new BigInteger(2); divisor * divisor <= value; divisor = divisor == 2 ? 3 : divisor + 2)
        { Step(); if (value % divisor == 0) return divisor; }
        return value;
    }
    internal ExactNumber SquareRoot(ExactNumber value)
    {
        Step();
        if (!value.IsRational)
        {
            // Exact quadratic denesting; higher nested extensions remain explicit errors.
            if (value.Radicals.Length != 1) throw new ArithmeticException("Nested radical is outside the supported exact field");
            var term = value.Radicals[0]; var a = value.Constant; var b = term.Coefficient;
            if (Sign(value) < 0) throw new ArithmeticException(NegativeRoot);
            var discriminant = a * a - b * b * new Rational(term.Radicand, 1);
            if (discriminant.Numerator.Sign < 0) throw new ArithmeticException("Nested radical is outside the supported exact field");
            var root = RationalRoot(discriminant);
            if (!root.IsRational) throw new ArithmeticException("Nested radical is outside the supported exact field");
            var left = (a + root.Rational) / new Rational(2, 1); var right = (a - root.Rational) / new Rational(2, 1);
            if (left.Numerator.Sign < 0 || right.Numerator.Sign < 0) throw new ArithmeticException("Nested radical is outside the supported exact field");
            var answer = Add(RationalRoot(left), Scale(RationalRoot(right), new Rational(b.Numerator.Sign, 1)));
            return Sign(answer) < 0 ? Negate(answer) : answer;
        }
        return RationalRoot(value.Rational);
    }
    private ExactNumber RationalRoot(Rational value)
    {
        if (value.Numerator.Sign < 0) throw new ArithmeticException(NegativeRoot);
        if (value.Numerator.IsZero) return default;
        var (outsideN, insideN) = ExtractSquares(value.Numerator);
        var (outsideD, insideD) = ExtractSquares(value.Denominator);
        var radicand = insideN * insideD;
        if (radicand.GetBitLength() > 4096) throw new ArithmeticException("Precision limit exceeded");
        var coefficient = new Rational(outsideN, outsideD * insideD);
        return radicand == 1 ? new(coefficient) : new(new SortedDictionary<BigInteger, Rational> { [radicand] = coefficient });
    }
    private (BigInteger Outside, BigInteger Inside) ExtractSquares(BigInteger value)
    {
        var root = IntegerRoot(value);
        if (root * root == value) return (root, 1);
        var outside = BigInteger.One; var inside = BigInteger.One;
        for (var divisor = new BigInteger(2); divisor * divisor <= value; divisor = divisor == 2 ? 3 : divisor + 2)
        {
            Step(); var count = 0;
            while (value % divisor == 0) { Step(); value /= divisor; count++; }
            if (count == 0) continue;
            outside *= BigInteger.Pow(divisor, count / 2);
            if ((count & 1) != 0) inside *= divisor;
            root = IntegerRoot(value);
            if (root * root == value) { outside *= root; value = 1; break; }
        }
        return (outside, inside * value);
    }
    internal BigInteger IntegerRoot(BigInteger value)
    {
        if (value.IsZero) return 0;
        var root = BigInteger.One << (int)((value.GetBitLength() + 1) / 2);
        while (true) { Step(); var next = (root + value / root) / 2; if (next >= root) return root; root = next; }
    }
    internal ExactNumber Power(ExactNumber value, Rational exponent)
    {
        if (exponent.Denominator != 1 && exponent.Denominator != 2 || BigInteger.Abs(exponent.Numerator) > 1024)
            throw new ArithmeticException("Exponent must be an integer or half-integer with numerator from -1024 to 1024");
        if (exponent.Denominator == 2) { value = SquareRoot(value); exponent = new(exponent.Numerator, 1); }
        var count = (int)BigInteger.Abs(exponent.Numerator); var answer = One;
        while (count > 0) { Step(); if ((count & 1) != 0) answer = Multiply(answer, value); count >>= 1; if (count > 0) value = Multiply(value, value); }
        return exponent.Numerator.Sign < 0 ? Divide(One, answer) : answer;
    }
    internal (Rational Lower, Rational Upper) Bounds(ExactNumber value, int bits)
    {
        var lower = value.Constant; var upper = lower; var denominator = BigInteger.One << bits;
        foreach (var term in value.Radicals)
        {
            Step(); var root = IntegerRoot(term.Radicand << (2 * bits));
            var lo = new Rational(root, denominator) * term.Coefficient;
            var hi = new Rational(root + 1, denominator) * term.Coefficient;
            lower += term.Coefficient.Numerator.Sign > 0 ? lo : hi;
            upper += term.Coefficient.Numerator.Sign > 0 ? hi : lo;
        }
        return (lower, upper);
    }
    internal int Sign(ExactNumber value)
    {
        if (value.IsRational) return value.Rational.Numerator.Sign;
        for (var bits = 16; bits <= 1024; bits *= 2)
        {
            var (lo, hi) = Bounds(value, bits);
            if (lo.Numerator.Sign > 0) return 1;
            if (hi.Numerator.Sign < 0) return -1;
        }
        throw new ArithmeticException("Radical comparison precision limit exceeded");
    }
    internal BigInteger Floor(ExactNumber value)
    {
        static BigInteger FloorRational(Rational r)
        { var q = BigInteger.DivRem(r.Numerator, r.Denominator, out var remainder); return r.Numerator.Sign < 0 && !remainder.IsZero ? q - 1 : q; }
        if (value.IsRational) return FloorRational(value.Rational);
        for (var bits = 16; bits <= 1024; bits *= 2)
        {
            var (lo, hi) = Bounds(value, bits); var floor = FloorRational(lo);
            if (floor == FloorRational(hi)) return floor;
        }
        throw new ArithmeticException("Radical comparison precision limit exceeded");
    }
}
