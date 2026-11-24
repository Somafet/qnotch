using Calc.Core;

namespace Calc.Core.Tests;

public class CalculusTests
{
    private static LineResult Last(string source) => SheetEvaluator.Evaluate(source)[^1];
    private static SheetValue Value(string source) { var result = Last(source); Assert.Null(result.Error); return result.Value!.Value; }
    private static double Double(string source) => double.Parse((Value(source).Number with { IsApproximate = false, DisplayDecimalPlaces = null }).Display, System.Globalization.CultureInfo.InvariantCulture);

    [Theory]
    [InlineData("integral(x^2, 0, 3)", "9")]
    [InlineData("derivative(x^3, 2)", "12")]
    public void PublishedReferenceExamples(string source, string display) => Assert.Equal(display, Value(source).Display);

    [Theory]
    [InlineData("integral(2x + 1, 1, 4)", "18")]
    [InlineData("integral(x, 3, 0)", "-4.5")]
    [InlineData("integral(x^2, 0, sqrt(2))^2", "8/9")]
    [InlineData("integral(t^2, 0, 3, t)", "9")]
    [InlineData("k = 2\nintegral(k*x, 0, 3)", "9")]
    [InlineData("x = 100\nintegral(x, 0, 2)", "2")]
    [InlineData("integral(x^2, 1, 1)", "0")]
    [InlineData("integral(sin(x), 1, 1)", "≈ 0")]
    [InlineData("integral(sin(x), 0, pi)", "≈ 2")]
    [InlineData("integral(1/x, 1, e)", "≈ 1")]
    [InlineData("derivative(t^3, 2, t)", "12")]
    [InlineData("derivative(3x^2 - 2x + 7, 5)", "28")]
    [InlineData("derivative(sin(x), 0)", "≈ 1")]
    [InlineData("derivative(ln(x), 2)", "≈ 0.5")]
    [InlineData("derivative(sqrt(x), 4)", "≈ 0.25")]
    [InlineData("derivative(abs(x), -2)", "≈ -1")]
    [InlineData("derivative(x^x, 1)", "≈ 1")]
    [InlineData("derivative(tan(x), 0)", "≈ 1")]
    [InlineData("derivative(exp(2x), 0)", "≈ 2")]
    [InlineData("a = sin(1)\nintegral(a*x, 0, 2)", "≈ 1.682941969616")]
    [InlineData("sin(0)", "≈ 0")]
    [InlineData("cos(pi)", "≈ -1")]
    [InlineData("exp(1)", "≈ 2.71828182846")]
    [InlineData("ln(e)", "≈ 1")]
    [InlineData("log(1000)", "≈ 3")]
    [InlineData("tanh(0)", "≈ 0")]
    [InlineData("sqrt(2)", "sqrt(2)")]
    [InlineData("abs(-3)", "3")]
    [InlineData("sin(50%)", "≈ 0.479425538604")]
    public void ExactAndNumericContracts(string source, string display) => Assert.Equal(display, Value(source).Display);

    [Theory]
    [InlineData("integral(exp(x), 0, 1)", 1.718281828459045)]
    [InlineData("integral(cos(x), 0, 2)", 0.9092974268256817)]
    [InlineData("derivative(sin(x^2), 1)", 1.0806046117362795)]
    [InlineData("derivative(x*sin(x), 1)", 1.3817732906760363)]
    [InlineData("derivative(exp(x), 1)", 2.718281828459045)]
    [InlineData("atan(1)*4", 3.141592653589793)]
    [InlineData("asin(0.5)*6", 3.141592653589793)]
    [InlineData("cosh(1)^2 - sinh(1)^2", 1)]
    public void AnalyticValuesWithinTolerance(string source, double expected) => Assert.InRange(Double(source), expected - 1e-9, expected + 1e-9);

    [Fact]
    public void NumericResultsAreMarkedApproximateWithMethodDisclosure()
    {
        var integral = Last("integral(sin(x), 0, pi)");
        Assert.True(integral.Value!.Value.Number.IsApproximate); Assert.Contains("Gauss-Kronrod", integral.Explanation[^1].Assumption);
        var derivative = Last("derivative(sin(x), 0)");
        Assert.Contains("cos(x)", derivative.Explanation[^1].Assumption);
        Assert.False(Value("integral(x^2, 0, 3)").Number.IsApproximate); Assert.False(Value("derivative(x^3, 2)").Number.IsApproximate);
        Assert.True(Value("a = sin(1)\nintegral(a*x, 0, 2)").Number.IsApproximate);
    }
    [Theory]
    [InlineData("integral(1/x, -1, 1)")][InlineData("integral(1/x, 0, 1)")][InlineData("integral(sin(1000x), 0, 1000)")][InlineData("integral(x, 0, 1 m)")][InlineData("integral(x^2, 0)")]
    [InlineData("integral(x^2, 0, 1, 2)")][InlineData("integral(sin(x), 0, 10^400)")][InlineData("integral(y, 0, 1)")][InlineData("derivative(x)")][InlineData("derivative(ln(x), 0)")]
    [InlineData("derivative(abs(x), 0)")][InlineData("derivative(x^2, 1 m)")][InlineData("asin(2)")][InlineData("ln(0)")][InlineData("sin(1 m)")][InlineData("sin(1, 2)")][InlineData("solutionRoot(sin(1), 1)")]
    public void DomainAndGrammarErrors(string source) => Assert.NotNull(Last(source).Error);

    [Fact]
    public void SavedFunctionsParseCanonicalizeAndReload()
    {
        var definitions = new FunctionDefinition[] { new("area", ["b"], "integral(x^2, 0, b)"), new("slope", ["p"], "derivative(x^3, p)"), new("wave", ["t"], "sin(t) * 2") };
        var library = new FunctionLibrary(definitions);
        Assert.Equal(FunctionLibrary.FormulaCatalogVersion, library.MinimumCatalogVersion);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("area(3)\nslope(2)\nwave(0)", library, []).Results;
        Assert.Equal(new[] { "9", "12", "≈ 0" }, results.Select(r => r.Display));
        var update = FunctionUpdate.Prepare("area(b) = integral(x^2, 0, b)", FunctionLibrary.Empty, []);
        Assert.Equal("9", new SheetEvaluationSession().EvaluateWithFunctions("area(3)", update.Library, []).Results[0].Display);
        Assert.Equal(1, new FunctionLibrary([new("plain", ["v"], "v + 1")]).MinimumCatalogVersion);
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("unbound", ["b"], "integral(x^2, 0, q)")]));
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("sin", ["v"], "v")]));
    }
    [Fact]
    public void CancellationAndStepBudgetApply()
    {
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("integral(sin(x), 0, 1)", cancellationToken: cancellation.Token));
        var definitions = Enumerable.Range(0, 12).Select(i => new FunctionDefinition("f" + i, ["x"], i == 0 ? "integral(sin(t), 0, x, t)" : $"f{i - 1}(x)+f{i - 1}(x)"));
        var values = new SheetEvaluationSession().EvaluateWithFunctions("f11(1)", new FunctionLibrary(definitions), []).Results;
        Assert.Equal("Expression step limit exceeded", values[0].Error);
    }

    // Expected values are the powers themselves: 2^20 = 1048576, 2^50 = 1125899906842624, 3^20 = 3486784401, 10^20 / 2 = 5 * 10^19.
    [Theory]
    [InlineData("solve x = 2^20", "x = 1048576")]
    [InlineData("solve x = 10^18", "x = 1000000000000000000")]
    [InlineData("solve x^2 = 2^100", "x = -1125899906842624 or x = 1125899906842624")]
    [InlineData("solve x = (-2)^21", "x = -2097152")]
    [InlineData("integral(2^20, 0, 1)", "1048576")]
    [InlineData("integral(10^20 * x, 0, 1)", "50000000000000000000")]
    [InlineData("integral((1/2)^20, 0, 1)", "0.00000095367431640625")]
    [InlineData("derivative(x * 3^20, 1)", "3486784401")]
    public void ConstantPowersInFormulasKeepTheirTrueExponent(string source, string display) => Assert.Equal(display, Value(source).Display);

    [Theory]
    [InlineData("solve x^2 - 1e-10 = 0")]
    [InlineData("integral(1e-10 + x, 0, 1)")]
    [InlineData("derivative(3e*x, 0)")]
    [InlineData("solve x = 2.5E3")]
    public void ScientificNotationInFormulasIsAnErrorNotEuler(string source) => Assert.Contains("Scientific notation", Last(source).Error);

    [Fact]
    public void ExplicitEulerAndAUserVariableNamedEStillWork()
    {
        Assert.InRange(Double("integral(2*e, 0, 1)"), 2 * Math.E - 1e-9, 2 * Math.E + 1e-9);
        Assert.Equal("x = 6", Value("e = 2\nsolve x = 3e").Display);
    }
}
