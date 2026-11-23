using System.Numerics;

namespace Calc.Core;

public sealed record IrrRootInterval(Rational LowerRate, Rational UpperRate, bool Exact);
public sealed record IrrEvidence(int DistinctRoots, Rational Guess, IReadOnlyList<IrrRootInterval> Roots, int SelectedRoot,
    int Refinements, string Method, bool InputApproximate, bool ToleranceTie);
internal sealed record IrrSolution(Rational Rate, IrrEvidence Evidence);

/// <summary>Positive-discount roots of the represented cash-flow polynomial, without floating-point sign guesses.</summary>
internal sealed class IrrSolver(ExecutionBudget budget, CancellationToken token)
{
    private const int MaxCoefficients = 16384, MaxVisits = 262144, MaxValueBits = 16384;
    private int visits, refinements;
    private static readonly Rational One = new(1,1);
    private readonly record struct Cell(Rational Lo, Rational Hi, int VLo, int VHi, bool UpperRoot = false);
    private void Step() => budget.Step(token);
    private void Visit()
    {
        if (++visits > MaxVisits) throw new ArithmeticException("IRR coefficient-work limit exceeded");
        if ((visits & 15) == 0) Step();
    }
    private void RefineStep()
    { Step(); if (++refinements > 8192) throw new ArithmeticException("IRR isolation limit exceeded"); }
    private static Rational Fraction(BigInteger n, BigInteger d)
    {
        if (d.IsZero) throw new ArithmeticException("Undefined IRR fraction");
        var common = BigInteger.GreatestCommonDivisor(n,d);
        return new(n/common,d/common);
    }
    private static Rational Add(Rational a, Rational b) => Fraction(a.Numerator*b.Denominator+b.Numerator*a.Denominator,a.Denominator*b.Denominator);
    private static Rational Subtract(Rational a, Rational b) => Fraction(a.Numerator*b.Denominator-b.Numerator*a.Denominator,a.Denominator*b.Denominator);
    private static Rational Half(Rational a) => Fraction(a.Numerator,a.Denominator*2);
    private static Rational Abs(Rational a) => new(BigInteger.Abs(a.Numerator),a.Denominator);
    private static int Compare(Rational a, Rational b) => (a.Numerator*b.Denominator).CompareTo(b.Numerator*a.Denominator);
    private static Rational Rate(Rational discount) => Fraction(discount.Denominator-discount.Numerator,discount.Numerator);
    private static Rational Discount(Rational rate) => Fraction(rate.Denominator,rate.Denominator+rate.Numerator);
    private static Rational MidRate(IrrRootInterval root) => Half(Add(root.LowerRate,root.UpperRate));
    private BigInteger[] Primitive(BigInteger[] polynomial)
    {
        var length = polynomial.Length;
        while (length > 0 && polynomial[length-1].IsZero) length--;
        if (length == 0) return [];
        var common = BigInteger.Zero;
        for (var i = 0; i < length; i++) { Step(); common = BigInteger.GreatestCommonDivisor(common,BigInteger.Abs(polynomial[i])); }
        var result = new BigInteger[length];
        for (var i = 0; i < length; i++)
        {
            Step(); result[i] = polynomial[i]/common;
            if (result[i].GetBitLength() > 4096) throw new ArithmeticException("IRR polynomial precision limit exceeded");
        }
        return result; // Positive content normalization preserves Sturm signs.
    }
    private BigInteger[] Polynomial(IReadOnlyList<Rational> flows)
    {
        var denominator = BigInteger.One;
        foreach (var value in flows)
        {
            Step(); denominator = denominator/BigInteger.GreatestCommonDivisor(denominator,value.Denominator)*value.Denominator;
            if (denominator.GetBitLength() > 4096) throw new ArithmeticException("IRR common-denominator limit exceeded");
        }
        var coefficients = new BigInteger[flows.Count];
        for (var i = 0; i < flows.Count; i++) { Step(); coefficients[i] = flows[i].Numerator*(denominator/flows[i].Denominator); }
        var start = 0; while (start < coefficients.Length && coefficients[start].IsZero) start++;
        return Primitive(coefficients[start..]); // A common q^k changes no positive-discount root.
    }
    private BigInteger[] Derivative(BigInteger[] polynomial)
    {
        var result = new BigInteger[polynomial.Length-1];
        for (var i = 1; i < polynomial.Length; i++) { Step(); result[i-1] = polynomial[i]*i; }
        return Primitive(result);
    }
    private BigInteger[] Remainder(BigInteger[] dividend, BigInteger[] divisor)
    {
        var remainder = dividend.ToArray();
        var leading = BigInteger.Abs(divisor[^1]); var sign = divisor[^1].Sign;
        while (remainder.Length >= divisor.Length)
        {
            Step(); var shift = remainder.Length-divisor.Length; var coefficient = remainder[^1];
            for (var i = 0; i < remainder.Length; i++) { Step(); remainder[i] *= leading; }
            for (var i = 0; i < divisor.Length; i++) { Step(); remainder[i+shift] -= coefficient*sign*divisor[i]; }
            remainder = Primitive(remainder);
        }
        return remainder;
    }
    private List<BigInteger[]> Chain(BigInteger[] polynomial)
    {
        var chain = new List<BigInteger[]> { polynomial,Derivative(polynomial) };
        var stored = chain.Sum(item=>item.Length);
        while (chain[^1].Length > 1)
        {
            var remainder = Remainder(chain[^2],chain[^1]);
            if (remainder.Length == 0) break;
            for (var i = 0; i < remainder.Length; i++) remainder[i] = -remainder[i];
            stored += remainder.Length;
            if (stored > MaxCoefficients) throw new ArithmeticException("IRR polynomial-storage limit exceeded");
            chain.Add(remainder);
        }
        return chain;
    }
    private BigInteger[] Quotient(BigInteger[] polynomial, BigInteger[] factor)
    {
        var remainder = polynomial.ToArray(); var result = new BigInteger[polynomial.Length-factor.Length+1];
        for (var shift = result.Length-1; shift >= 0; shift--)
        {
            Step(); var coefficient = BigInteger.DivRem(remainder[shift+factor.Length-1],factor[^1],out var rest);
            if (!rest.IsZero) throw new ArithmeticException("IRR exact factorization failed");
            result[shift] = coefficient;
            for (var i = 0; i < factor.Length; i++) { Step(); remainder[i+shift] -= coefficient*factor[i]; }
        }
        if (remainder.Any(value=>!value.IsZero)) throw new ArithmeticException("IRR exact factorization failed");
        return Primitive(result);
    }
    private static BigInteger Floor(BigInteger value, BigInteger denominator)
    { var whole = BigInteger.DivRem(value,denominator,out var rest); return value.Sign < 0 && !rest.IsZero ? whole-1 : whole; }
    private static BigInteger Ceiling(BigInteger value, BigInteger denominator)
    { var whole = BigInteger.DivRem(value,denominator,out var rest); return value.Sign > 0 && !rest.IsZero ? whole+1 : whole; }
    private static void Range(BigInteger value)
    { if (value.GetBitLength() > MaxValueBits) throw new ArithmeticException("IRR sign-evaluation range limit exceeded"); }
    private int Sign(BigInteger[] polynomial, Rational at)
    {
        // Directed integer rounding encloses exact Horner values at a positive rational endpoint.
        for (var bits = 128; bits <= 1024; bits *= 2)
        {
            var scale = BigInteger.One << bits;
            var lower = polynomial[^1]*scale; var upper = lower;
            for (var i = polynomial.Length-2; i >= 0; i--)
            {
                Visit(); var term = polynomial[i]*scale;
                lower = Floor(lower*at.Numerator,at.Denominator)+term;
                upper = Ceiling(upper*at.Numerator,at.Denominator)+term;
                Range(lower); Range(upper);
            }
            if (lower.Sign > 0) return 1;
            if (upper.Sign < 0) return -1;
            if (lower.IsZero && upper.IsZero) return 0;
        }
        // An exact rational hit must not be mistaken for a tiny residual. Bound the homogeneous fallback.
        var value = polynomial[^1]; var power = BigInteger.One;
        for (var i = polynomial.Length-2; i >= 0; i--)
        {
            Visit(); power *= at.Denominator; Range(power);
            value = value*at.Numerator+polynomial[i]*power; Range(value);
        }
        return value.Sign;
    }
    private static int Variations(IEnumerable<int> signs)
    {
        var previous = 0; var result = 0;
        foreach (var sign in signs)
        { if (sign == 0) continue; if (previous != 0 && previous != sign) result++; previous = sign; }
        return result;
    }
    private (int Variations, bool Root) At(List<BigInteger[]> chain, Rational at)
    {
        var signs = new int[chain.Count];
        for (var i = 0; i < signs.Length; i++) signs[i] = Sign(chain[i],at);
        return (Variations(signs),signs[0] == 0);
    }
    private (Rational Lower, Rational Upper) Bounds(BigInteger[] polynomial)
    {
        var upperRatio = default(Rational); var reverseRatio = default(Rational);
        for (var i = 0; i < polynomial.Length; i++)
        {
            Step();
            if (i < polynomial.Length-1)
            { var ratio = Fraction(BigInteger.Abs(polynomial[i]),BigInteger.Abs(polynomial[^1])); if (Compare(ratio,upperRatio)>0) upperRatio=ratio; }
            if (i > 0)
            { var ratio = Fraction(BigInteger.Abs(polynomial[i]),BigInteger.Abs(polynomial[0])); if (Compare(ratio,reverseRatio)>0) reverseRatio=ratio; }
        }
        var reverse = Add(One,reverseRatio);
        return (Fraction(reverse.Denominator,reverse.Numerator),Add(One,upperRatio));
    }
    private static int Log2(Rational value)
    {
        var exponent = (int)(value.Numerator.GetBitLength()-value.Denominator.GetBitLength());
        if (exponent >= 0 ? value.Numerator < value.Denominator << exponent : value.Numerator << -exponent < value.Denominator) exponent--;
        return exponent;
    }
    private static Rational Midpoint(Rational lower, Rational upper)
    {
        var lo = Log2(lower); var hi = Log2(upper);
        if (hi-lo > 2)
        {
            var exponent = lo+(hi-lo)/2;
            var dyadic = exponent >= 0 ? new Rational(BigInteger.One << exponent,1) : new Rational(1,BigInteger.One << -exponent);
            if (Compare(dyadic,lower)>0 && Compare(dyadic,upper)<0) return dyadic;
        }
        return Half(Add(lower,upper));
    }
    private Rational Rounded(Rational rate)
        => ExactRounding.Apply(RoundingKind.DecimalPlaces,new NumericValue(rate,true),new(new Rational(4,1)),token).Scalar;
    private bool Accurate(Rational lowerRate, Rational upperRate)
    {
        var width = Subtract(upperRate,lowerRate); var middle = Abs(Half(Add(lowerRate,upperRate)));
        var tolerance = Compare(middle,One)>0 ? middle : One;
        return width.Numerator*tolerance.Denominator*BigInteger.Pow(10,14) <= tolerance.Numerator*width.Denominator;
    }
    private IrrRootInterval Refine(Cell cell, BigInteger[] polynomial, List<BigInteger[]>? chain, Rational guess)
    {
        var lower = cell.Lo; var upper = cell.Hi; var vLower = cell.VLo;
        if (cell.UpperRoot) { var root=Rate(upper); return new(root,root,true); }
        foreach (var candidate in new[] { Discount(guess),One })
            if (Compare(candidate,lower)>0 && Compare(candidate,upper)<=0 && Sign(polynomial,candidate)==0)
            { var root=Rate(candidate); return new(root,root,true); }
        var lowerSign = polynomial[0].Sign;
        for (var iteration = 0; iteration < 256; iteration++)
        {
            RefineStep(); var rateLower = Rate(upper); var rateUpper = Rate(lower);
            if (Accurate(rateLower,rateUpper))
            {
                var roundedLower = Rounded(rateLower); var roundedUpper = Rounded(rateUpper);
                if (roundedLower == roundedUpper) return new(rateLower,rateUpper,false);
                var boundary = Half(Add(roundedLower,roundedUpper));
                if (Compare(boundary,rateLower)>=0 && Compare(boundary,rateUpper)<0 && Sign(polynomial,Discount(boundary))==0)
                    return new(boundary,boundary,true);
            }
            var middle = Midpoint(lower,upper);
            if (chain is null)
            {
                var sign = Sign(polynomial,middle);
                if (sign == 0) { var root=Rate(middle); return new(root,root,true); }
                if (sign == lowerSign) lower=middle; else upper=middle;
            }
            else
            {
                var (variation,root) = At(chain,middle);
                if (root) { var exact=Rate(middle); return new(exact,exact,true); }
                if (vLower-variation == 1) upper=middle;
                else { lower=middle; vLower=variation; }
            }
        }
        throw new ArithmeticException("IRR refinement did not converge within 256 steps");
    }
    internal IrrSolution Solve(IReadOnlyList<Rational> cash, Rational guess)
    {
        if (cash.Count < 2) throw new ArithmeticException("IRR requires at least two cash flows");
        if (cash.All(value=>value.Numerator.IsZero)) throw new ArithmeticException("IRR is indeterminate for all-zero cash flows");
        if (!cash.Any(value=>value.Numerator.Sign>0) || !cash.Any(value=>value.Numerator.Sign<0)) throw new ArithmeticException("IRR requires both positive and negative cash flows");
        var polynomial = Polynomial(cash);
        var roots = new List<IrrRootInterval>(); string method;
        if (polynomial.Length == 2)
        {
            var discount = Fraction(-polynomial[0],polynomial[1]);
            if (discount.Numerator.Sign <= 0) throw new ArithmeticException("No admissible IRR with rate greater than -100%");
            var rate = Rate(discount); roots.Add(new(rate,rate,true)); method="Exact linear cash-flow root";
        }
        else if (Variations(polynomial.Select(value=>value.Sign)) == 1)
        {
            var bounds = Bounds(polynomial);
            roots.Add(Refine(new(bounds.Lower,bounds.Upper,1,0),polynomial,null,guess));
            method="Descartes unique positive-discount root; directed sign enclosures";
        }
        else
        {
            var chain = Chain(polynomial);
            if (chain[^1].Length > 1) { polynomial=Quotient(polynomial,chain[^1]); chain=Chain(polynomial); }
            var vZero = Variations(chain.Select(item=>item.First(value=>!value.IsZero).Sign));
            var vInfinity = Variations(chain.Select(item=>item[^1].Sign));
            if (vZero < vInfinity) throw new ArithmeticException("IRR root-count verification failed");
            if (vZero == vInfinity) throw new ArithmeticException("No admissible IRR with rate greater than -100%");
            var bounds = Bounds(polynomial); var cells = new Stack<Cell>(); cells.Push(new(bounds.Lower,bounds.Upper,vZero,vInfinity));
            while (cells.TryPop(out var cell))
            {
                var count = cell.VLo-cell.VHi;
                if (count == 1) { roots.Add(Refine(cell,polynomial,chain,guess)); continue; }
                RefineStep(); var midpoint = Midpoint(cell.Lo,cell.Hi); var (variation,root) = At(chain,midpoint);
                if (variation < cell.VHi || variation > cell.VLo) throw new ArithmeticException("IRR isolation-count verification failed");
                if (variation-cell.VHi > 0) cells.Push(new(midpoint,cell.Hi,variation,cell.VHi,cell.UpperRoot));
                if (cell.VLo-variation > 0) cells.Push(new(cell.Lo,midpoint,cell.VLo,variation,root));
            }
            roots.Reverse(); // Positive discount order is the reverse of rate order.
            method="Square-free Sturm isolation of all distinct positive-discount roots";
        }
        var selected = 0; var tie = false;
        var distance = Abs(Subtract(MidRate(roots[0]),guess));
        for (var i = 1; i < roots.Count; i++)
        {
            Step(); var candidate = Abs(Subtract(MidRate(roots[i]),guess));
            var difference = Abs(Subtract(candidate,distance)); var scale = Compare(distance,One)>0 ? distance : One;
            var close = difference.Numerator*scale.Denominator*BigInteger.Pow(10,12) <= scale.Numerator*difference.Denominator;
            if (close) { tie=true; continue; } // Ascending rates: lower rate wins a tolerance tie.
            if (Compare(candidate,distance)<0) { selected=i; distance=candidate; tie=false; }
        }
        return new(MidRate(roots[selected]),new(roots.Count,guess,Array.AsReadOnly(roots.ToArray()),selected,refinements,method,false,tie));
    }
}
