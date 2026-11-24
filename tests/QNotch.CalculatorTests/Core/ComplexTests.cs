using Calc.Core;

namespace Calc.Core.Tests;

public class ComplexTests
{
    private static LineResult Last(string source) => SheetEvaluator.Evaluate(source)[^1];
    private static SheetValue Value(string source) { var result = Last(source); Assert.Null(result.Error); return result.Value!.Value; }
    private static double Real(string source) { var value = Value(source).Number.Exact.Rational; return (double)value.Numerator / (double)value.Denominator; }

    [Theory]
    [InlineData("(3 + 4i) * (1 - 2i)", "11 - 2i")]
    [InlineData("sqrt(-4)", "2i")]
    public void PublishedReferenceExamples(string source, string display)
    { var value = Value(source); Assert.Equal(SheetValueKind.Complex, value.Kind); Assert.Equal(display, value.Display); }

    [Theory]
    [InlineData("i", "i")]
    [InlineData("-i", "-i")]
    [InlineData("4i", "4i")]
    [InlineData("2.5i", "2.5i")]
    [InlineData(".5i", "0.5i")]
    [InlineData("1 + i", "1 + i")]
    [InlineData("-3 - 4i", "-3 - 4i")]
    [InlineData("1/3 + 2/3*i", "1/3 + (2/3)*i")]
    [InlineData("sqrt(-2)", "sqrt(2)*i")]
    [InlineData("sqrt(-12)", "2*sqrt(3)*i")]
    [InlineData("sqrt(2) + sqrt(3)*i", "sqrt(2) + sqrt(3)*i")]
    [InlineData("(1 + sqrt(2))*i", "(1 + sqrt(2))*i")]
    [InlineData("1 - (1 + sqrt(2))*i", "1 - (1 + sqrt(2))*i")]
    public void DisplayFormsAreExactAndPasteBack(string source, string display)
    {
        var value = Value(source);
        Assert.Equal(display, value.Display); Assert.Equal(display, value.CopyText); Assert.False(value.Complex.IsApproximate);
        Assert.Equal(value, Value(value.CopyText));
    }

    // Field axioms over exact Gaussian rationals. Each difference must be an exact real zero.
    [Theory]
    [InlineData("3+4i", "1-2i", "-2+7i")]
    [InlineData("1/2+1/3*i", "-5+7i", "2i")]
    [InlineData("sqrt(2)+i", "1-sqrt(3)*i", "3")]
    public void FieldIdentitiesHoldExactly(string z, string w, string u)
    {
        foreach (var identity in new[]
        {
            $"({z})*({w}) - ({w})*({z})", $"({z})+({w}) - (({w})+({z}))", $"(({z})+({w}))-({w}) - ({z})", $"(({z})*({w}))/({w}) - ({z})",
            $"({z})*(({w})+({u})) - (({z})*({w}) + ({z})*({u}))", $"(({z})*({w}))*({u}) - ({z})*(({w})*({u}))", $"({z})*(1/({z})) - 1",
            $"conj(({z})*({w})) - conj({z})*conj({w})", $"abs(({z})*({w}))^2 - abs({z})^2*abs({w})^2"
        })
        {
            var result = Value(identity);
            Assert.Equal(SheetValueKind.Number, result.Kind); Assert.Equal("0", result.Display); Assert.False(result.Number.IsApproximate);
        }
    }
    [Theory]
    [InlineData(3, 4)]
    [InlineData(5, -12)]
    [InlineData(-7, 24)]
    public void ConjugateProductIsTheSquaredNorm(int a, int b)
    {
        var z = $"({a} + {b}*i)";
        Assert.Equal((a * a + b * b).ToString(), Value($"{z} * conj({z})").Display);
        Assert.Equal(Math.Sqrt(a * a + b * b).ToString(), Value($"abs({z})").Display);
    }
    [Theory]
    [InlineData("(1+2i)/(3-4i)", "-0.2 + 0.4i")] // (1+2i)(3+4i)/25 = (-5+10i)/25
    [InlineData("1/i", "-i")]
    [InlineData("i^2", "-1")]
    [InlineData("i^3", "-i")]
    [InlineData("i^4", "1")]
    [InlineData("i^-1", "-i")]
    [InlineData("(2+i)^3", "2 + 11i")] // (2+i)^2 = 3+4i, times 2+i
    [InlineData("(1+i)^10", "32i")] // de Moivre: 2^5 at angle 5pi/2
    [InlineData("(1+i)^-2", "-0.5i")]
    [InlineData("(1+i)^0", "1")]
    [InlineData("(1+i)^1024", "13407807929942597099574024998205846127479365820592393377723561443721764030073546976801874298166903427690031858186486050853753882811946569946433649006084096")] // (2i)^512 = 2^512
    public void PowersAndQuotientsMatchHandComputedValues(string source, string display) => Assert.Equal(display, Value(source).Display);
    [Theory]
    [InlineData("sqrt(-4)", "2i")]
    [InlineData("sqrt(-1/4)", "0.5i")]
    [InlineData("sqrt(3+4i)", "2 + i")] // (2+i)^2 = 3+4i
    [InlineData("sqrt(5-12i)", "3 - 2i")] // (3-2i)^2 = 5-12i
    [InlineData("sqrt(2i)", "1 + i")]
    [InlineData("sqrt(-2i)", "1 - i")]
    [InlineData("sqrt(-3+4i)", "1 + 2i")] // negative real part stays in the principal right half plane
    [InlineData("(3+4i)^0.5", "2 + i")]
    [InlineData("(-4)^0.5", "2i")]
    [InlineData("(-4)^1.5", "-8i")] // principal branch: 8 at angle 3pi/2
    [InlineData("(-4)^-0.5", "-0.5i")]
    public void PrincipalRootsSquareBackExactly(string source, string display) => Assert.Equal(display, Value(source).Display);
    [Fact]
    public void RealRadicalsAndPrincipalBranchRemainExact()
    {
        Assert.Equal("-2", Value("sqrt(-2)^2").Display);
        Assert.Equal("-sqrt(6)", Value("sqrt(-2)*sqrt(-3)").Display); // Not sqrt(6): the product rule fails across the branch cut.
        Assert.Equal("sqrt(2)", Value("abs(1+i)").Display);
        Assert.Equal("sqrt(2)", Value("sqrt(2)").Display); Assert.Equal("2", Value("4^0.5").Display);
    }
    [Fact]
    public void RootsWithoutASimpleExactFormAreMarkedApproximate()
    {
        var root = Value("sqrt(1+i)");
        Assert.True(root.Complex.IsApproximate); Assert.StartsWith("≈ ", root.Display);
        // |sqrt(1+i)|^2 = sqrt(2) and sqrt(1+i)^2 = 1+i, both within double rounding at 12 significant digits.
        Assert.InRange(Real("abs(sqrt(1+i))^2"), Math.Sqrt(2) - 1e-9, Math.Sqrt(2) + 1e-9);
        Assert.InRange(Real("re(sqrt(1+i)^2)"), 1 - 1e-9, 1 + 1e-9); Assert.InRange(Real("im(sqrt(1+i)^2)"), 1 - 1e-9, 1 + 1e-9);
        Assert.True(Value("sqrt(-pi)").Complex.IsApproximate);
        Assert.InRange(Real("im(sqrt(-pi))"), 1.7724538509 - 1e-9, 1.7724538509 + 1e-9);
        Assert.True(Value("abs(1234567891+987654321i)").Number.IsApproximate);
    }
    [Fact]
    public void ApproximationPropagatesThroughEveryPart()
    {
        var product = Value("pi*i");
        Assert.True(product.Complex.IsApproximate); Assert.Equal("≈ 3.14159265359i", product.Display); Assert.Equal("3.14159265358979i", product.CopyText);
        Assert.True(Value("re(pi + i)").Number.IsApproximate); Assert.True(Value("(pi*i)^2").Number.IsApproximate);
        Assert.StartsWith("Approximate input/result", Last("pi*i").Explanation[^1].Assumption);
    }
    [Theory]
    [InlineData("arg(1+i)", Math.PI / 4)]
    [InlineData("arg(-1)", Math.PI)]
    [InlineData("arg(-i)", -Math.PI / 2)]
    [InlineData("arg(-1-i)", -3 * Math.PI / 4)]
    public void ArgIsThePrincipalAngle(string source, double expected)
    {
        var value = Value(source);
        Assert.True(value.Number.IsApproximate); Assert.InRange(Real(source), expected - 1e-10, expected + 1e-10);
    }
    [Fact]
    public void PartsAndArgOfRealNumbers()
    {
        Assert.Equal("3", Value("re(3+4i)").Display); Assert.Equal("4", Value("im(3+4i)").Display); Assert.Equal("3 - 4i", Value("conj(3+4i)").Display);
        Assert.Equal("5", Value("re(5)").Display); Assert.Equal("0", Value("im(5)").Display); Assert.Equal("5", Value("conj(5)").Display);
        Assert.Equal("0", Value("arg(5)").Display); Assert.False(Value("arg(5)").Number.IsApproximate);
        Assert.InRange(Real("arg(1+sqrt(3)*i)"), Math.PI / 3 - 1e-10, Math.PI / 3 + 1e-10);
    }
    [Theory]
    [InlineData("i*i", "-1")]
    [InlineData("(1+2i)-(1+2i)", "0")]
    [InlineData("(1+2i)+(1-2i)", "2")]
    [InlineData("0i", "0")]
    [InlineData("0i + 1", "1")]
    [InlineData("(1+i)*(1-i)", "2")]
    public void AZeroImaginaryPartCollapsesToARealNumber(string source, string display)
    {
        var value = Value(source);
        Assert.Equal(SheetValueKind.Number, value.Kind); Assert.Equal(display, value.Display); Assert.Equal(value, Value(display));
        Assert.Equal(display == "0" ? "2" : (int.Parse(display) + 2).ToString(), Value($"({source}) + 2").Display);
    }
    [Fact]
    public void AUserVariableNamedIAlwaysWins()
    {
        var results = SheetEvaluator.Evaluate("i = 5\ni\n2*i\ni^2");
        Assert.Equal(new[] { "5", "5", "10", "25" }, results.Select(result => result.Display));
        Assert.All(results, result => Assert.Equal(SheetValueKind.Number, result.Value!.Value.Kind));
        Assert.NotNull(Last("i = 5\n4i").Error); // No implicit multiplication: the variable never silently becomes the imaginary unit.
        Assert.Equal("10", Last("I = 5\n2*i").Display); // Sheet names ignore case, so this variable shadows i too.
        var update = FunctionUpdate.Prepare("twice(i) = i + i", FunctionLibrary.Empty, []);
        Assert.Equal("6", new SheetEvaluationSession().EvaluateWithFunctions("twice(3)", update.Library, []).Results[0].Display);
    }
    [Theory]
    [InlineData("I")]
    [InlineData("i think so")]
    [InlineData("i in km")]
    public void ProseAndUppercaseStayProse(string source) { var result = SheetEvaluator.Evaluate(source)[0]; Assert.Null(result.Value); Assert.Null(result.Error); }
    [Fact]
    public void LabelsBeforeNumbersStayLabels() => Assert.Equal("5", Value("i 5").Display);
    [Fact]
    public void ASpacedSuffixIsNotTheImaginaryUnit() => Assert.Equal("Unexpected text", Last("4 i").Error);
    [Theory]
    [InlineData("(1+2i) m")]
    [InlineData("5 m + i")]
    [InlineData("i * 2 kg")]
    [InlineData("(1+2i) USD")]
    [InlineData("$5 * i")]
    [InlineData("$5 + i")]
    [InlineData("10% + i")]
    [InlineData("[1,2] * i")]
    [InlineData("(1+i) per month")]
    public void UnitsMoneyPercentagesAndCollectionsAreRefused(string source)
    {
        var result = Last(source);
        Assert.Null(result.Value); Assert.Contains("plain numbers", result.Error);
    }
    [Theory]
    [InlineData("sqrt(-4 m^2)", "no real square root")]
    [InlineData("[1, i]", "Lists require")] // Matrices and lists of complex values are out of scope.
    [InlineData("[[1, i], [2, 3]]", "Lists require")]
    [InlineData("2^i", "exponent")]
    [InlineData("i^i", "exponent")]
    [InlineData("i^(1/3)", "exponent")]
    [InlineData("i^pi", "exponent")]
    [InlineData("(1+i)^1025", "exponent")]
    [InlineData("i!", "Unsupported")]
    [InlineData("i%", "Unsupported")]
    [InlineData("(1+i)/0", "Division by zero")]
    [InlineData("arg(0)", "undefined")]
    [InlineData("sin(i)", "dimensionless")]
    [InlineData("solve x + i = 0", "real-valued")]
    [InlineData("integral(i*x, 0, 1)", "real-valued")]
    [InlineData("re(1, 2)", "expects 1")]
    public void UnsupportedOperationsFailExplicitly(string source, string message)
    {
        var result = Last(source);
        Assert.Null(result.Value); Assert.Contains(message, result.Error);
    }
    [Fact]
    public void AggregatesSkipComplexLinesWithoutCrashing()
    {
        var results = SheetEvaluator.Evaluate("1 + i\n3\n5\nsum\naverage");
        Assert.Equal("8", results[3].Display); Assert.Equal("4", results[4].Display);
        Assert.Contains("complex", results[3].Explanation[^1].Assumption);
        Assert.Equal("3", Last("1 + i #t\n3 #t\nsum #t").Display);
    }
    [Fact]
    public void RoundingAppliesToEachPart()
    {
        Assert.Equal("0.33 + 0.67i", Value("(1/3 + 2/3*i) to 2 decimals").Display);
        Assert.Equal("i", Value("i to 2 decimals").Display);
        Assert.Equal("0.3", Value("(0.3 + 0.01i) to 1 decimals").Display); // A part rounded to zero collapses as well.
    }
    [Fact]
    public void ScalingAndDependenciesWork()
    {
        Assert.Equal("1 + 2i", Value("half of (2+4i)").Display);
        Assert.Equal("2 + 2i", Last("z = 1 + i\ndouble z").Display); Assert.Equal("0.5 + 0.5i", Last("z = 1 + i\nhalf z").Display); Assert.Equal("2i", Value("2 of i").Display);
        var results = SheetEvaluator.Evaluate("z = 1 + 2i\nz^2\nz * conj(z)");
        Assert.Equal("-3 + 4i", results[1].Display); Assert.Equal("5", results[2].Display); Assert.Equal(new[] { 0 }, results[1].Dependencies);
        Assert.Contains("rincipal", Last("sqrt(-4)").Explanation[^1].Assumption);
    }
    [Fact]
    public void SavedFunctionsParseCanonicalizeAndReload()
    {
        var update = FunctionUpdate.Prepare("rotate(z) = z * (1 + 2i)\nnorm2(z) = z * conj(z)", FunctionLibrary.Empty, []);
        Assert.Equal(FunctionLibrary.LatestCatalogVersion, update.Library.MinimumCatalogVersion); Assert.Equal(5, FunctionLibrary.LatestCatalogVersion);
        var reloaded = new FunctionLibrary(update.Library.Definitions);
        Assert.Equal(update.Library.Fingerprint, reloaded.Fingerprint);
        Assert.Equal(reloaded.Fingerprint, new FunctionLibrary(update.Library.Definitions.Select(definition => definition with { Body = definition.Body.Replace(" ", "") })).Fingerprint);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("rotate(3 + 4i)\nnorm2(3 + 4i)", reloaded, []).Results;
        Assert.Equal(new[] { "-5 + 10i", "25" }, results.Select(result => result.Display));
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("conj", ["z"], "z")]));
    }
    [Fact]
    public void CancellationPropagates()
    {
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => SheetEvaluator.Evaluate("(1+i)^1024", cancelled.Token));
    }
}
