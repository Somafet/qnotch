namespace Calc.Core;

public enum EquationSolutionScope { AllRealRoots, BracketedRoots, Identity }
public sealed record EquationRoot(NumericValue Value, Rational? Lower = null, Rational? Upper = null);

/// <summary>Immutable solution set of one real equation. Display, copy and explanation text derive from the retained roots.</summary>
public sealed record EquationValue
{
    public const int MaxRoots = 16;
    public string Variable { get; }
    public IReadOnlyList<EquationRoot> Roots { get; }
    public EquationSolutionScope Scope { get; }
    public string Method { get; }
    public string Summary { get; }
    public string Details { get; }
    public bool Truncated { get; }
    /// <summary>True when a from/to domain restricted the reported roots.</summary>
    public bool InDomain { get; }
    public bool IsApproximate => Roots.Any(root => root.Value.IsApproximate);
    internal EquationValue(string variable, IEnumerable<EquationRoot> roots, EquationSolutionScope scope, string method, string summary, bool truncated = false, bool inDomain = false)
    {
        var copy = roots.ToArray(); if (copy.Length > MaxRoots) throw new ArithmeticException("Equation result limit exceeded");
        Variable = variable; Roots = Array.AsReadOnly(copy); Scope = scope; Method = method; Summary = summary; Truncated = truncated; InDomain = inDomain;
        var claim = scope switch
        {
            EquationSolutionScope.BracketedRoots => copy.Length == 0 ? "No sign change was found in the search window; this is not proof that no solution exists." :
                (truncated ? "More sign changes exist; narrow the domain with from a to b. " : "") + "Bracketed roots in the search window only; roots without a sign change and roots outside the window are not found. No claim of completeness.",
            EquationSolutionScope.Identity => "Every real value solves this identity.",
            _ => "All distinct real roots in the stated domain; repeated roots appear once. Complex roots are out of scope."
        };
        Details = method + "\n" + claim + (copy.Length == 0 ? "" : "\n" + string.Join("\n", copy.Select((root, i) => "Root " + (i + 1) + ": " + Full(root.Value) +
            (root.Lower is { } lower ? "; exact enclosure [" + lower + ", " + root.Upper + "]" : root.Value.IsApproximate ? "; bisection to double precision" : "; exact"))));
        if (Details.Length > 16384) throw new ArithmeticException("Equation result limit exceeded");
    }
    private static string Full(NumericValue value) => (value with { IsApproximate = false, DisplayDecimalPlaces = null }).Display;
    private string Join(Func<NumericValue, string> format, int limit) => string.Join(" or ", Roots.Take(limit).Select(root => Variable + (root.Value.IsApproximate ? " ≈ " : " = ") + format(root.Value)))
        + (Roots.Count > limit ? " … (" + Roots.Count + " roots)" : "");
    public string Display => Scope == EquationSolutionScope.Identity ? "All real " + Variable : Roots.Count == 0 ? Scope == EquationSolutionScope.BracketedRoots ? "No root found" : InDomain ? "No real solutions in the domain" : "No real solutions"
        : Join(value => (value with { IsApproximate = false }).Display, 6);
    public string CopyText => Roots.Count == 0 || Scope == EquationSolutionScope.Identity ? Display : Join(Full, MaxRoots);
}

// Cross-cancel before constructing a bounded fraction, avoiding oversized reducible intermediates.
internal static class EquationFraction
{
    internal static Rational Add(Rational a, Rational b)
    { var g = System.Numerics.BigInteger.GreatestCommonDivisor(a.Denominator, b.Denominator); return Reduced(a.Numerator * (b.Denominator / g) + b.Numerator * (a.Denominator / g), (a.Denominator / g) * b.Denominator); }
    internal static Rational Negate(Rational a) => new(-a.Numerator, a.Denominator);
    internal static Rational Subtract(Rational a, Rational b) => Add(a, Negate(b));
    internal static Rational Multiply(Rational a, Rational b)
    {
        var g = System.Numerics.BigInteger.GreatestCommonDivisor(a.Numerator, b.Denominator); var h = System.Numerics.BigInteger.GreatestCommonDivisor(b.Numerator, a.Denominator);
        if (g.IsZero) g = System.Numerics.BigInteger.One; if (h.IsZero) h = System.Numerics.BigInteger.One;
        return new((a.Numerator / g) * (b.Numerator / h), (a.Denominator / h) * (b.Denominator / g));
    }
    internal static Rational Divide(Rational a, Rational b) => Multiply(a, new(b.Denominator, b.Numerator));
    private static Rational Reduced(System.Numerics.BigInteger n, System.Numerics.BigInteger d)
    { var g = System.Numerics.BigInteger.GreatestCommonDivisor(n, d); return g.IsZero ? new(n, d) : new(n / g, d / g); }
    internal static int Compare(Rational a, Rational b) => (a.Numerator * b.Denominator).CompareTo(b.Numerator * a.Denominator);
    internal static Rational Abs(Rational a) => new(System.Numerics.BigInteger.Abs(a.Numerator), a.Denominator);
    internal static Rational Half(Rational a) => Divide(a, new(2, 1));
}
