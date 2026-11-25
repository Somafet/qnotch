using System.Numerics;
using static Calc.Core.EquationFraction;
namespace Calc.Core;

/// <summary>Bounded rational polynomial arithmetic and square-free Sturm isolation, in ascending coefficient order.</summary>
internal sealed class EquationPolynomial(ExactArithmetic math, ExecutionBudget budget, CancellationToken token)
{
    private int refinements;
    private void Step() => budget.Step(token);
    internal Rational[] Trim(Rational[] p) { var n = p.Length; while (n > 0 && p[n - 1].Numerator.IsZero) n--; return p[..n]; }
    internal Rational[] Sum(Rational[] a, Rational[] b, bool subtract = false)
    {
        Step(); var p = new Rational[Math.Max(a.Length, b.Length)];
        for (var i = 0; i < p.Length; i++) { var right = i < b.Length ? b[i] : default; p[i] = Add(i < a.Length ? a[i] : default, subtract ? Negate(right) : right); }
        return Trim(p);
    }
    internal Rational[] Product(Rational[] a, Rational[] b)
    {
        Step(); if (a.Length == 0 || b.Length == 0) return [];
        if (a.Length + b.Length - 2 > FormulaPolynomial.MaxDegree) throw new ArithmeticException("Polynomial degree limit is " + FormulaPolynomial.MaxDegree);
        var p = new Rational[a.Length + b.Length - 1];
        for (var i = 0; i < a.Length; i++) for (var j = 0; j < b.Length; j++) { token.ThrowIfCancellationRequested(); p[i + j] = Add(p[i + j], Multiply(a[i], b[j])); }
        return Trim(p);
    }
    internal Rational[] Scale(Rational[] p, Rational scalar) { Step(); return Trim(p.Select(v => Multiply(v, scalar)).ToArray()); }
    internal Rational[] Power(Rational[] p, int exponent) { Rational[] result = [new(1, 1)]; for (var i = 0; i < exponent; i++) result = Product(result, p); return result; }
    internal Rational Evaluate(Rational[] p, Rational x)
    { Step(); var value = new Rational(0, 1); for (var i = p.Length - 1; i >= 0; i--) value = Add(Multiply(value, x), p[i]); return value; }
    internal ExactNumber EvaluateExact(Rational[] p, ExactNumber x)
    { Step(); var value = new ExactNumber(new Rational(0, 1)); for (var i = p.Length - 1; i >= 0; i--) value = math.Add(math.Multiply(value, x), new(p[i])); return value; }
    internal Rational[] Derivative(Rational[] p) { Step(); return Trim(p.Skip(1).Select((c, i) => Multiply(c, new(i + 1, 1))).ToArray()); }
    internal Rational[] Antiderivative(Rational[] p) { Step(); return Trim(new Rational[] { new(0, 1) }.Concat(p.Select((c, i) => Divide(c, new(i + 1, 1)))).ToArray()); }
    private (Rational[] Quotient, Rational[] Remainder) DividePolynomial(Rational[] a, Rational[] b)
    {
        Step(); if (b.Length == 0) throw new ArithmeticException("Zero polynomial divisor");
        var r = a.ToArray(); var q = new Rational[Math.Max(0, a.Length - b.Length + 1)];
        for (var k = a.Length - b.Length; k >= 0; k--)
        {
            token.ThrowIfCancellationRequested(); var factor = Divide(r[k + b.Length - 1], b[^1]); q[k] = factor;
            for (var j = 0; j < b.Length; j++) r[k + j] = Subtract(r[k + j], Multiply(factor, b[j]));
        }
        return (Trim(q), Trim(r));
    }
    private Rational[] Normalize(Rational[] p) => p.Length == 0 ? p : Scale(p, Divide(new(1, 1), Abs(p[^1]))); // Positive scaling preserves Sturm signs.
    private List<Rational[]> Chain(Rational[] p)
    {
        var list = new List<Rational[]> { Normalize(p), Normalize(Derivative(p)) };
        while (list[^1].Length > 0)
        { var remainder = DividePolynomial(list[^2], list[^1]).Remainder; if (remainder.Length == 0) break; list.Add(Normalize(Scale(remainder, new(-1, 1)))); }
        return list;
    }
    private int Variations(List<Rational[]> chain, Rational at)
    {
        var previous = 0; var changes = 0;
        foreach (var p in chain) { var sign = Evaluate(p, at).Numerator.Sign; if (sign == 0) continue; if (previous != 0 && previous != sign) changes++; previous = sign; }
        return changes;
    }
    private static bool Accurate(Rational lo, Rational hi)
    {
        var scale = Abs(Half(Add(lo, hi))); if (Compare(scale, new(1, 1)) < 0) scale = new(1, 1);
        return Compare(Subtract(hi, lo), Divide(scale, new(BigInteger.Pow(10, 14), 1))) <= 0;
    }
    private Rational? Reconstruct(Rational[] p, Rational lo, Rational hi)
    {
        var value = Half(Add(lo, hi)); var n = value.Numerator; var d = value.Denominator;
        BigInteger hn = 1, hp = 0, kn = 0, kp = 1;
        for (var i = 0; i < 64 && !d.IsZero; i++)
        {
            Step(); var a = BigInteger.DivRem(n, d, out var rem); if (rem.Sign < 0) { a--; rem += d; }
            var h = a * hn + hp; var k = a * kn + kp; if (k.GetBitLength() > 40) break;
            if (!k.IsZero)
            { var candidate = new Rational(h, k); if (Compare(candidate, lo) >= 0 && Compare(candidate, hi) <= 0 && Evaluate(p, candidate).Numerator.IsZero) return candidate; }
            hp = hn; hn = h; kp = kn; kn = k; n = d; d = rem;
        }
        return null;
    }
    /// <summary>All distinct real roots of p inside the optional closed domain; repeated roots once. Complex roots are never reported.</summary>
    internal (EquationRoot[] Roots, bool Identity, string Method) Solve(Rational[] p, Rational? domainLo = null, Rational? domainHi = null)
    {
        p = Trim(p); if (p.Length <= 1) return ([], p.Length == 0, "Exact constant polynomial classification");
        bool Inside(ExactNumber value) => (domainLo is null || math.Sign(math.Subtract(value, new(domainLo.Value))) >= 0) && (domainHi is null || math.Sign(math.Subtract(value, new(domainHi.Value))) <= 0);
        static EquationRoot Exact(ExactNumber value) => new(new NumericValue(value));
        if (p.Length == 2)
        { var root = new ExactNumber(Divide(Negate(p[0]), p[1])); return (Inside(root) ? [Exact(root)] : [], false, "Exact linear solution -b/a"); }
        if (p.Length == 3)
        {
            var discriminant = Subtract(Multiply(p[1], p[1]), Multiply(new(4, 1), Multiply(p[2], p[0])));
            if (discriminant.Numerator.Sign < 0) return ([], false, "Exact quadratic formula; negative discriminant, no real roots");
            var square = math.SquareRoot(new(discriminant)); var denominator = Multiply(new(2, 1), p[2]);
            var a = math.Scale(math.Subtract(new(Negate(p[1])), square), Divide(new(1, 1), denominator));
            var b = math.Scale(math.Add(new(Negate(p[1])), square), Divide(new(1, 1), denominator));
            var values = (a == b ? new[] { a } : math.Sign(math.Subtract(a, b)) < 0 ? new[] { a, b } : new[] { b, a }).Where(Inside).ToArray();
            foreach (var value in values)
                if (!EvaluateExact(p, value).IsZero) throw new ArithmeticException("Quadratic root substitution failed");
            return (values.Select(Exact).ToArray(), false, "Exact quadratic formula verified by substitution");
        }
        var chain = Chain(p);
        if (chain[^1].Length > 1)
        { var division = DividePolynomial(p, chain[^1]); if (division.Remainder.Length > 0) throw new ArithmeticException("Square-free polynomial verification failed"); p = division.Quotient; chain = Chain(p); }
        var bound = BigInteger.One;
        foreach (var c in p[..^1])
        { var ratio = Divide(Abs(c), Abs(p[^1])); var ceiling = (ratio.Numerator + ratio.Denominator - 1) / ratio.Denominator; if (ceiling >= bound) bound = ceiling + 1; }
        var lo = new Rational(-bound, 1); var hi = new Rational(bound, 1);
        if (domainLo is { } dl && Compare(dl, lo) > 0) lo = dl; if (domainHi is { } dh && Compare(dh, hi) < 0) hi = dh;
        if (Compare(lo, hi) > 0) return ([], false, "Exact Cauchy root bound excludes the requested domain");
        var roots = new List<EquationRoot>(); var expected = Variations(chain, lo) - Variations(chain, hi);
        var lowRoot = Evaluate(p, lo).Numerator.IsZero; if (lowRoot) roots.Add(Exact(new(lo)));
        var cells = new Stack<(Rational Lo, Rational Hi, int VLo, int VHi)>(); if (expected > 0) cells.Push((lo, hi, Variations(chain, lo), Variations(chain, hi)));
        while (cells.TryPop(out var cell))
        {
            Step(); if (++refinements > 2048) throw new ArithmeticException("Root isolation limit exceeded");
            var count = cell.VLo - cell.VHi; if (count <= 0) continue;
            if (count == 1 && Evaluate(p, cell.Hi).Numerator.IsZero) { roots.Add(Exact(new(cell.Hi))); continue; }
            if (count == 1 && Accurate(cell.Lo, cell.Hi))
            {
                var rational = Reconstruct(p, cell.Lo, cell.Hi);
                var estimate = FormulaNumbers.ToDouble(Half(Add(cell.Lo, cell.Hi)));
                roots.Add(rational is { } r ? Exact(new(r)) : new(new NumericValue(FormulaNumbers.FromDouble(estimate)) { IsApproximate = true, DisplayDecimalPlaces = FormulaNumbers.RootPlaces(estimate) }, cell.Lo, cell.Hi));
                continue;
            }
            var middle = Half(Add(cell.Lo, cell.Hi)); var vm = Variations(chain, middle);
            if (vm < cell.VHi || vm > cell.VLo) throw new ArithmeticException("Sturm root-count verification failed");
            if (vm > cell.VHi) cells.Push((middle, cell.Hi, vm, cell.VHi));
            if (cell.VLo > vm) cells.Push((cell.Lo, middle, cell.VLo, vm));
        }
        if (roots.Count != expected + (lowRoot ? 1 : 0)) throw new ArithmeticException("Root coverage verification failed");
        roots.Sort((a, b) => math.Sign(math.Subtract(a.Value.Exact, b.Value.Exact)));
        return (roots.ToArray(), false, "Exact square-free Sturm count with disjoint rational isolation; rational roots reconstructed, others enclosed to 14 digits");
    }
}
