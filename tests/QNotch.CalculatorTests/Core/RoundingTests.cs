using System.Globalization;
using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class RoundingTests
{
    public static IEnumerable<object[]> Fixtures()
    {
        using var stream = typeof(RoundingTests).Assembly.GetManifestResourceStream("Calc.RoundingFixtures")!;
        using var document = JsonDocument.Parse(stream);
        return document.RootElement.GetProperty("cases").EnumerateArray()
            .Select(item => new object[] { item.GetProperty("input").GetString()!, item.GetProperty("expected").GetString()! }).ToArray();
    }
    private static NumericValue Evaluate(string expression)
    {
        var result = SheetEvaluator.Evaluate(expression)[0];
        Assert.Null(result.Error);
        return Assert.IsType<SheetValue>(result.Value).Number;
    }
    [Theory]
    [MemberData(nameof(Fixtures))]
    public void ExactFixtures(string source, string expected) => Assert.Equal(expected, Evaluate(source).Display);

    [Theory]
    [InlineData("2 to -1 decimals")]
    [InlineData("2 to 257 decimals")]
    [InlineData("2 to 2.5 decimals")]
    [InlineData("2 to 2% decimals")]
    [InlineData("2 to 0 sig figs")]
    [InlineData("2 to 257 sig figs")]
    [InlineData("0 to 0 sig figs")]
    [InlineData("0 to -1 decimals")]
    [InlineData("2 to nearest 0")]
    [InlineData("2 to nearest -1")]
    [InlineData("2 to nearest 1%")]
    [InlineData("2% to nearest 1")]
    [InlineData("2 to nearest")]
    [InlineData("2 to 2")]
    [InlineData("2 to 2 sig")]
    [InlineData("2 to 2 significant")]
    [InlineData("2 to 2 decimals + 1")]
    [InlineData("2 to nearest 0.5 + 1")]
    [InlineData("2 to (2^1000) decimals")]
    public void InvalidInputsNeverPublishANumber(string source)
    {
        var result = SheetEvaluator.Evaluate(source)[0];
        Assert.NotNull(result.Error); Assert.Null(result.Value);
    }
    [Fact]
    public void DecimalRoundingMatchesIndependentDecimalArithmetic()
    {
        var random = new Random(7519);
        for (var sample = 0; sample < 1000; sample++)
        {
            var value = random.Next(-10_000_000, 10_000_001) / 1000m;
            var places = random.Next(0, 7);
            var expected = decimal.Round(value, places, MidpointRounding.AwayFromZero);
            Assert.Equal(Rational.Parse(expected.ToString(CultureInfo.InvariantCulture)),
                Evaluate($"{value.ToString(CultureInfo.InvariantCulture)} to {places} decimals").Scalar);
        }
    }
    [Fact]
    public void IncrementRoundingMatchesDecimalAndPreservesGridAndErrorBounds()
    {
        var random = new Random(3814);
        decimal[] steps = [.01m, .05m, .25m, 2.5m, 7m, .003m];
        for (var sample = 0; sample < 500; sample++)
        {
            var value = random.Next(-1_000_000, 1_000_001) / 1000m; var step = steps[random.Next(steps.Length)];
            var source = $"{value.ToString(CultureInfo.InvariantCulture)} to nearest {step.ToString(CultureInfo.InvariantCulture)}";
            var rounded = Evaluate(source).Scalar;
            var expected = decimal.Round(value / step, 0, MidpointRounding.AwayFromZero) * step;
            Assert.Equal(Rational.Parse(expected.ToString(CultureInfo.InvariantCulture)), rounded);
            var quantum = Rational.Parse(step.ToString(CultureInfo.InvariantCulture));
            Assert.Equal(BigInteger.One, (rounded / quantum).Denominator);
            var error = rounded - Rational.Parse(value.ToString(CultureInfo.InvariantCulture));
            Assert.True(BigInteger.Abs(error.Numerator) * quantum.Denominator * 2 <= quantum.Numerator * error.Denominator);
            Assert.Equal(rounded, Evaluate($"({source}) to nearest {step.ToString(CultureInfo.InvariantCulture)}").Scalar);
        }
    }
    [Fact]
    public void SignificantFiguresMatchAnIndependentDecimalScaleOracle()
    {
        var random = new Random(8291);
        for (var sample = 0; sample < 500; sample++)
        {
            var value = random.Next(-1_000_000, 1_000_001) / 10_000_000m;
            if (value == 0) continue;
            var figures = random.Next(1, 7); var normalized = decimal.Abs(value); var scale = 1m;
            while (normalized >= 10) { normalized /= 10; scale *= 10; }
            while (normalized < 1) { normalized *= 10; scale /= 10; }
            for (var digit = 1; digit < figures; digit++) scale /= 10;
            var expected = decimal.Round(value / scale, 0, MidpointRounding.AwayFromZero) * scale;
            Assert.Equal(Rational.Parse(expected.ToString(CultureInfo.InvariantCulture)),
                Evaluate($"{value.ToString(CultureInfo.InvariantCulture)} to {figures} sig figs").Scalar);
        }
    }
    [Fact]
    public void VariablesFunctionsAndExplanationsRetainTypedRounding()
    {
        var source = "places=2\ncost to date=12.375\ncost to date to places decimals\nround(x)=x*2\nrounded(x,p)=x to p decimals\nrounded(12.345%,2)\nround(3)\n100+L6";
        var results = SheetEvaluator.Evaluate(source);
        Assert.Equal("12.38", results[2].Display); Assert.Equal(new[] { 0, 1 }, results[2].Dependencies);
        Assert.Equal("12.35%", results[5].Display); Assert.True(results[5].Value!.Value.IsPercentage);
        Assert.Equal("6", results[6].Display); Assert.Equal("112.35", results[7].Display);
        Assert.Contains(results[2].Explanation, step => step.Operation == "round to decimal places" && step.Assumption!.Contains("away from zero"));
        Assert.Contains(results[5].Explanation, step => step.Assumption?.StartsWith("rounded(", StringComparison.Ordinal) == true);
    }
    [Fact]
    public void RoundedAggregatesExcludeThemselvesAndSeparatePrecisionDependencies()
    {
        var source = "places=2\n# Costs\n1.234 #x\n2.345 #x\nsum to places decimals #x\naverage to 3 sig figs #x\nsum";
        var results = SheetEvaluator.Evaluate(source);
        Assert.Equal("3.58", results[4].Display); Assert.Equal(new[] { 0, 2, 3 }, results[4].Dependencies);
        Assert.Equal("1.79", results[5].Display); Assert.Equal("3.579", results[6].Display);
    }
    [Fact]
    public void AggregateMembershipChangesInvalidateCacheEvenWhenUnionOfDependenciesIsUnchanged()
    {
        var session = new SheetEvaluationSession();
        Assert.Equal("3.23", session.Evaluate("places=2 #x\n1.234 #x\nsum to places decimals #x")[2].Display);
        Assert.Equal("1.23", session.Evaluate("places=2\n1.234 #x\nsum to places decimals #x")[2].Display);
        var changed = session.Evaluate("places=1\n1.234 #x\nsum to places decimals #x");
        Assert.Equal("1.2", changed[2].Display);
        Assert.Equal(1, session.LastStatistics.ReusedResults);
    }
    [Fact]
    public void VeryLargeAndSmallRationalValuesKeepExactMagnitudeAndBounds()
    {
        Assert.Equal(new Rational(107 * BigInteger.Pow(10, 299), 1), Evaluate("(2^1000 + 1) to 3 sig figs").Scalar);
        var tiny = Evaluate("(1/(2^1000+1)) to 3 sig figs").Scalar;
        Assert.Equal(new Rational(933, BigInteger.Pow(10, 304)), tiny);
        Assert.Equal("1", Evaluate("((2^1000+1)/2^1000) to 256 sig figs").Display);
        Assert.Equal("0", Evaluate("(1/(2^1000+1)) to 256 decimals").Display);
        var limit = SheetEvaluator.Evaluate("(1/((2^1023)^4+1)) to 256 sig figs")[0];
        Assert.Equal("Precision limit exceeded", limit.Error);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("(1/3) to 256 sig figs", cancellation.Token));
    }
}
