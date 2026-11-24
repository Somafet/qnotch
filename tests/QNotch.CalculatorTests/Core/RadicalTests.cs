using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class RadicalTests
{
    public static IEnumerable<object[]> Fixtures()
    {
        using var stream = typeof(RadicalTests).Assembly.GetManifestResourceStream("Calc.RadicalFixtures")!;
        using var json = JsonDocument.Parse(stream);
        return json.RootElement.GetProperty("cases").EnumerateArray().Select(item => new object[]
            { item.GetProperty("source").GetString()!, item.GetProperty("expected").GetString()! }).ToArray();
    }
    [Theory]
    [MemberData(nameof(Fixtures))]
    public void ExactIndependentFixtures(string source, string expected)
    {
        var results = SheetEvaluator.Evaluate(source);
        Assert.All(results, result => Assert.Null(result.Error));
        Assert.Equal(expected, results[^1].Display);
        var answer = results[^1].Value!.Value;
        var pasted = SheetEvaluator.Evaluate(answer.Display)[0];
        Assert.Null(pasted.Error); Assert.Equal(answer, pasted.Value!.Value);
    }
    [Fact]
    public void RationalAccessorNeverApproximatesARadical()
    {
        var value = SheetEvaluator.Evaluate("sqrt(2)")[0].Value!.Value;
        Assert.False(value.IsRational);
        Assert.Throws<ArithmeticException>(() => value.Scalar);
        Assert.True(default(NumericValue).IsRational); Assert.Equal("0", default(NumericValue).Display);
    }
    [Fact]
    public void CanonicalValuesSupportHashingAndIncrementalDependencies()
    {
        var a = SheetEvaluator.Evaluate("sqrt(8)")[0].Value!.Value;
        var b = SheetEvaluator.Evaluate("2*sqrt(2)")[0].Value!.Value;
        Assert.Equal(a, b); Assert.Equal(a.GetHashCode(), b.GetHashCode());
        var session = new SheetEvaluationSession();
        session.Evaluate("a=sqrt(2)\na^2\n7");
        var changed = session.Evaluate("a=sqrt(3)\na^2\n7");
        Assert.Equal("3", changed[1].Display); Assert.Equal(new[] { 0 }, changed[1].Dependencies);
        Assert.True(session.LastStatistics.ReusedResults > 0);
        Assert.Contains(changed[1].Explanation, step => step.Operation == "^" && step.Result == "3");
        var failed = session.Evaluate("a=sqrt(-1 m^2)\na^2\n7");
        Assert.Null(failed[1].Value); Assert.NotNull(failed[1].Error);
    }
    [Fact]
    public void PersistentFunctionsKeepRadicalArgumentsAndResultsExact()
    {
        var update = FunctionUpdate.Prepare("f(x)=x*x\ng(x)=sqrt(x)", FunctionLibrary.Empty, []);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("f(sqrt(7))\ng(8)", update.Library, []).Results;
        Assert.Equal(new[] { "7", "2*sqrt(2)" }, results.Select(result => result.Display));
    }
    [Fact]
    public void SeededRootsAndConjugatesSatisfyIndependentIntegerIdentities()
    {
        var random = new Random(2047);
        for (var trial = 0; trial < 250; trial++)
        {
            var n = random.Next(1, 1000); var d = random.Next(1, 1000); var a = random.Next(1, 30);
            var square = SheetEvaluator.Evaluate($"sqrt({n}/{d})^2")[0];
            Assert.Null(square.Error); Assert.Equal(new Rational(n, d), square.Value!.Value.Scalar);
            var norm = SheetEvaluator.Evaluate($"({a}+sqrt({n}))*({a}-sqrt({n}))")[0];
            Assert.Null(norm.Error); Assert.Equal(new Rational(a * a - n, 1), norm.Value!.Value.Scalar);
        }
    }
    [Fact]
    public void IndependentNestedFieldsRationalizeWithoutLosingTerms()
    {
        foreach (var denominator in new[] { "sqrt(2)+sqrt(3)+sqrt(5)", "1+sqrt(6)+sqrt(10)+sqrt(15)", "1+sqrt(2)+sqrt(3)+sqrt(6)", "sqrt(30)+sqrt(42)+sqrt(70)+sqrt(105)" })
        {
            var result = SheetEvaluator.Evaluate($"(1/({denominator}))*({denominator})")[0];
            Assert.Null(result.Error); Assert.Equal("1", result.Display);
        }
    }
    [Fact]
    public void SeededMixedFieldDivisionAndAssociativityRemainExact()
    {
        var random = new Random(8242);
        int[] roots = [2, 3, 5, 6, 7, 10, 14, 15, 21];
        for (var trial = 0; trial < 150; trial++)
        {
            var a = random.Next(1, 8); var b = roots[random.Next(roots.Length)]; var c = roots[random.Next(roots.Length)];
            var denominator = $"{a}+sqrt({b})+sqrt({c})";
            var answer = SheetEvaluator.Evaluate($"({denominator})/({denominator})")[0];
            Assert.Null(answer.Error); Assert.Equal("1", answer.Display);
            var identity = SheetEvaluator.Evaluate($"(sqrt({b})+sqrt({c}))*{a}-({a}*sqrt({b})+{a}*sqrt({c}))")[0];
            Assert.Null(identity.Error); Assert.Equal("0", identity.Display);
        }
    }
    [Fact]
    public void IndependentDecimalSquareBoundsAgreeWithExplicitRounding()
    {
        for (var n = 2; n < 200; n++)
        {
            // Small integer exhaustive search is independent of the implementation's Newton/bounds method.
            var floor = 0;
            while ((floor + 1L) * (floor + 1) <= n * 10000L) floor++;
            var rounded = 4L * n * 10000 >= (2L * floor + 1) * (2L * floor + 1) ? floor + 1 : floor;
            var answer = SheetEvaluator.Evaluate($"sqrt({n}) to 2 decimals")[0];
            Assert.Null(answer.Error); Assert.Equal(new Rational(rounded, 100), answer.Value!.Value.Scalar);
        }
    }
    [Fact]
    public void CloseRoundingBoundariesAreComparedExactly()
    {
        var p = BigInteger.One; var q = BigInteger.One;
        for (var iteration = 0; iteration < 60; iteration++)
        {
            (p, q) = (p + 2 * q, p + q);
            var expected = p * p > 2 * q * q ? "1" : "2";
            Assert.Equal(expected, SheetEvaluator.Evaluate($"1.5+sqrt(2)-{p}/{q} to 0 decimals")[0].Display);
        }
    }
    [Theory]
    [InlineData("sqrt(-1 m^2)")]
    [InlineData("1/(sqrt(2)-sqrt(2))")]
    [InlineData("sqrt(2)!")]
    [InlineData("2^sqrt(2)")]
    [InlineData("sqrt(1+sqrt(2))")]
    [InlineData("sqrt(2+sqrt(2)+sqrt(3))")]
    [InlineData("sqrt(2) to sqrt(2) decimals")]
    [InlineData("sqrt(2) to nearest -sqrt(3)")]
    [InlineData("sqrt(2)% to nearest sqrt(3)")]
    [InlineData("sqrt(100000000000000000000000000000000000003)")]
    public void InvalidDomainsAndExhaustedFactorBudgetsHaveNoValue(string source)
    {
        var result = SheetEvaluator.Evaluate(source)[0];
        Assert.Null(result.Value); Assert.NotNull(result.Error);
    }
    [Fact]
    public void LargePerfectSquaresBypassFactoringAndCancellationPropagates()
    {
        var answer = SheetEvaluator.Evaluate("sqrt(10^1000)")[0];
        Assert.Null(answer.Error); Assert.Equal(new Rational(BigInteger.Pow(10, 500), 1), answer.Value!.Value.Scalar);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("sqrt(100000000000000000003)", cancellation.Token));
        var many = string.Join('+', new[] { 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107, 109, 113, 127, 131, 137 }.Select(n => $"sqrt({n})"));
        Assert.NotNull(SheetEvaluator.Evaluate(many)[0].Error);
    }
    [Fact]
    public void FactoringConsumesTheSharedSheetBudgetWithoutCommittingPartialCaches()
    {
        var session = new SheetEvaluationSession();
        session.Evaluate("sqrt(2)\nprev^2"); var before = session.LastStatistics;
        Assert.Throws<SheetComputationLimitException>(() => session.Evaluate(string.Join('\n', Enumerable.Repeat("sqrt(1000000007)", 40))));
        Assert.Equal(before, session.LastStatistics);
        Assert.Equal("2", session.Evaluate("sqrt(2)\nprev^2")[1].Display);
        Assert.Equal(2, session.LastStatistics.ReusedResults);
    }
}
