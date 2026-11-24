using Calc.Core;

namespace Calc.Core.Tests;

public class EquationTests
{
    private static LineResult Last(string source) => SheetEvaluator.Evaluate(source)[^1];
    private static SheetValue Value(string source) { var result = Last(source); Assert.Null(result.Error); return result.Value!.Value; }
    private static double Double(SheetValue value) => double.Parse((value.Number with { IsApproximate = false, DisplayDecimalPlaces = null }).Display, System.Globalization.CultureInfo.InvariantCulture);

    [Theory]
    [InlineData("solve 2x + 3 = 11", "x = 4")]
    [InlineData("solve x^2 - 5x + 6 = 0", "x = 2 or x = 3")]
    [InlineData("solve cos(x) = x", "x ≈ 0.7391")]
    public void PublishedReferenceExamples(string source, string display) => Assert.Equal(display, Value(source).Display);

    [Fact]
    public void DottieNumberIsBracketedToPublishedDigits()
    {
        var root = Value("roots = solve cos(x) = x\nsolutionRoot(roots, 1)");
        Assert.True(root.Number.IsApproximate); Assert.InRange(Double(root), 0.7390851332 - 1e-9, 0.7390851332 + 1e-9);
        var equation = Value("solve cos(x) = x").Equation;
        Assert.Equal(EquationSolutionScope.BracketedRoots, equation.Scope); Assert.Equal("x ≈ 0.739085133215", equation.CopyText);
        Assert.Contains("claim of completeness", equation.Details, StringComparison.OrdinalIgnoreCase); Assert.StartsWith("Approximate:", equation.Summary);
        Assert.StartsWith("Approximate input/result", Last("solve cos(x) = x").Explanation[^1].Assumption);
    }
    [Fact]
    public void VietaAndSubstitutionHoldForExactRoots()
    {
        var values = SheetEvaluator.Evaluate("q = solve x^2 - 5x + 6 = 0\nsolutionRoot(q,1) + solutionRoot(q,2)\nsolutionRoot(q,1) * solutionRoot(q,2)\nsolutionCount(q)\nr = solve x^2 = 2\nsolutionRoot(r,2)^2\nr");
        Assert.Equal(new[] { "5", "6", "2" }, values.Skip(1).Take(3).Select(v => v.Display));
        Assert.Equal("2", values[5].Display); Assert.Equal("x = -sqrt(2) or x = sqrt(2)", values[6].Display);
        Assert.Contains(1, values[1].Dependencies.Select(d => d + 1)); Assert.Equal("x = 2 or x = 3", values[0].Display);
    }
    [Theory]
    [InlineData("solve x^3 - 6x^2 + 11x - 6 = 0", "x = 1 or x = 2 or x = 3")]
    [InlineData("solve x^2 - 2x + 1 = 0", "x = 1")]
    [InlineData("solve x^3 - 4x^2 + 5x - 2 = 0", "x = 1 or x = 2")]
    [InlineData("solve x^3 = 2", "x ≈ 1.2599")]
    [InlineData("solve x^4 - 5x^2 + 4 = 0", "x = -2 or x = -1 or x = 1 or x = 2")]
    [InlineData("solve x^2 + 1 = 0", "No real solutions")]
    [InlineData("solve x = x", "All real x")]
    [InlineData("solve 1 = 2", "No real solutions")]
    [InlineData("solve 2(x+1) = 8", "x = 3")]
    [InlineData("solve x(x - 1) = 0", "x = 0 or x = 1")]
    [InlineData("solve 3t = 12 for t", "t = 4")]
    [InlineData("solve 2y + 1 = 7 for y from 0 to 10", "y = 3")]
    [InlineData("solve y^2 = 9 for y from 0 to 5", "y = 3")]
    [InlineData("solve x^2 = 4 from 0 to 5", "x = 2")]
    [InlineData("solve x^2 = 2 from 0 to 2", "x = sqrt(2)")]
    [InlineData("solve sin(x) = 0 from 1 to 4", "x ≈ 3.1416")]
    [InlineData("solve exp(x) = 0", "No root found")]
    [InlineData("solve tan(x) = 0 from 1 to 2", "No root found")]
    [InlineData("solve x = pi", "x ≈ 3.1416")]
    [InlineData("x = 5\nsolve x^2 = 9", "x = -3 or x = 3")]
    [InlineData("a = 3\nb = 12\nsolve a*x = b", "x = 4")]
    [InlineData("solve = 5\nsolve + 1", "6")]
    [InlineData("1\nsolve x = 2\n3\nsum", "4")]
    [InlineData("pi", "≈ 3.14159265358979")]
    [InlineData("e = 2\n2*e", "4")]
    public void PolynomialNumericAndSentenceContracts(string source, string display) => Assert.Equal(display, Value(source).Display);

    [Fact]
    public void CubeRootIsEnclosedAndMarkedApproximate()
    {
        var equation = Value("solve x^3 = 2").Equation;
        var root = Assert.Single(equation.Roots); Assert.True(root.Value.IsApproximate); Assert.NotNull(root.Lower);
        Assert.InRange(Double(new SheetValue(root.Value)), 1.25992104989 - 1e-9, 1.25992104989 + 1e-9);
        Assert.Equal(EquationSolutionScope.AllRealRoots, equation.Scope);
    }
    [Fact]
    public void NumericScanReportsCountTruncationAndNotProof()
    {
        var values = SheetEvaluator.Evaluate("s = solve sin(x) = 0\nsolutionCount(s)\nmany = solve sin(100x) = 0\nsolutionCount(many)\nnone = solve exp(x) = 0");
        Assert.Equal("7", values[1].Display); Assert.StartsWith("x ≈ -9.4248 or", values[0].Display); Assert.EndsWith("… (7 roots)", values[0].Display);
        Assert.Equal("16", values[3].Display); Assert.True(values[2].Value!.Value.Equation.Truncated); Assert.Contains("narrow the domain", values[2].Value!.Value.Equation.Details);
        Assert.Contains("not proof", values[4].Value!.Value.Equation.Details);
    }
    [Fact]
    public void SheetVariablesAreDependenciesAndProseIsUntouched()
    {
        var values = SheetEvaluator.Evaluate("rate = 0.5\nsolve rate * x = 3\nsolve the problem");
        Assert.Equal("x = 6", values[1].Display); Assert.Equal(new[] { 0 }, values[1].Dependencies);
        Assert.Null(values[2].Error); Assert.Null(values[2].Value);
        // A user variable named solve wins: the sentence is disabled for that sheet and the line is an ordinary error.
        var shadowed = SheetEvaluator.Evaluate("solve = 7\nsolve 2x = 4\nsolve * 2");
        Assert.NotNull(shadowed[1].Error); Assert.Equal("14", shadowed[2].Display);
    }
    [Theory]
    [InlineData("solve x =")][InlineData("solve x = 1 = 2")][InlineData("solve foo(x) = 1")][InlineData("solve x = 1 from 5 to 1")][InlineData("solve x^2 = 4 for 2")]
    [InlineData("solve 1/0 = x")][InlineData("solve x = 1 m")][InlineData("solve x! = 1")][InlineData("r = solve x = 2\nr + 1")][InlineData("solutionRoot(1, 1)")]
    [InlineData("r = solve x = 2\nsolutionRoot(r, 2)")][InlineData("r = solve x = x\nsolutionCount(r)")][InlineData("solutionCount()")][InlineData("solve x = 2 for x from 0")]
    public void InvalidEquationsAreErrors(string source) => Assert.NotNull(Last(source).Error);

    [Fact]
    public void SavedFunctionsSolveAndCanonicalize()
    {
        var update = FunctionUpdate.Prepare("roots(c) = solve x^2 = c\nfirstRoot(c) = solutionRoot(roots(c), 1)", FunctionLibrary.Empty, []);
        Assert.Equal(FunctionLibrary.FormulaCatalogVersion, update.Library.MinimumCatalogVersion);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("roots(9)\nfirstRoot(9)", update.Library, []).Results;
        Assert.Equal("x = -3 or x = 3", results[0].Display); Assert.Equal("-3", results[1].Display);
        Assert.Equal(update.Library.Fingerprint, new FunctionLibrary(update.Library.Definitions).Fingerprint);
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("bad", ["c"], "solve x^2 = d")]));
    }
    [Fact]
    public void CancellationAndSharedBudgetApply()
    {
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("solve cos(x) = x", cancellationToken: cancellation.Token));
        Assert.Throws<SheetComputationLimitException>(() => SheetEvaluator.Evaluate(string.Join('\n', Enumerable.Repeat("solve sin(x) = 0.1", 300))));
        Assert.Equal("x = 4", Value("solve 2x + 3 = 11").Display);
    }

    // sqrt(10^-10) = 10^-5, ln(1.00001) = 9.99995e-6 and cbrt(2) * 10^-5 = 1.259921e-5, each shown to four significant digits.
    [Theory]
    [InlineData("solve x^2 = 10^-10", "x ≈ -0.00001 or x ≈ 0.00001")]
    [InlineData("solve exp(x) = 1.00001", "x ≈ 0.00001")]
    [InlineData("solve x^3 = 2/10^15", "x ≈ 0.0000126")]
    [InlineData("solve x^3 = 2", "x ≈ 1.2599")]
    public void SmallApproximateRootsKeepSignificantDigits(string source, string display) => Assert.Equal(display, Value(source).Display);

    [Theory]
    [InlineData("solve 2x = 4 from 0 to 1", "No real solutions in the domain")]
    [InlineData("solve x = 5 from 0 to 10%", "No real solutions in the domain")]
    [InlineData("solve 2x = 4", "x = 2")]
    [InlineData("solve x^2 + 1 = 0", "No real solutions")]
    public void EmptyDomainResultNamesTheDomain(string source, string display) => Assert.Equal(display, Value(source).Display);
}
