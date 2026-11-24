using Calc.Core;
namespace Calc.Core.Tests;
public class EvaluatorTests
{
    [Theory]
    [InlineData("0.1 + 0.2", "0.3")]
    [InlineData("2 + 3 * 4", "14")]
    [InlineData("(2 + 3) * 4", "20")]
    [InlineData("-2 * -3", "6")]
    [InlineData("120 * 15%", "18")]
    [InlineData("120 * (1 - 15%)", "102")]
    [InlineData("100 + 10%", "110")]
    [InlineData("1 / 3 * 3", "1")]
    [InlineData("1 / 3", "1/3")]
    [InlineData(".5 + .25", "0.75")]
    public void ExactArithmetic(string source, string expected) => Assert.Equal(expected, SheetEvaluator.Evaluate(source)[0].Display);
    [Fact]
    public void FailedAssignmentsInvalidateOlderValue()
    {
        var results = SheetEvaluator.Evaluate("a=2\na=1/0\na+1");
        Assert.Equal("Division by zero", results[1].Error);
        Assert.Equal("Dependency L2 unavailable", results[2].Error);
    }
    [Theory]
    [InlineData("2 +")]
    [InlineData("2 3")]
    [InlineData("2 + typo")]
    [InlineData("1..2")]
    [InlineData("(1")]
    public void InvalidInputHasNoValue(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[0].Error);
    [Fact]
    public void LimitsAndCancellation()
    {
        Assert.NotNull(SheetEvaluator.Evaluate(new string('(', 100) + "1")[0].Error);
        Assert.Throws<ArgumentException>(() => SheetEvaluator.Evaluate(new string('1', 200001)));
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("1+1", cancellation.Token));
        Assert.Equal(10000, SheetEvaluator.Evaluate(string.Join('\n', Enumerable.Repeat("1+1", 10000))).Count);
    }
    [Fact]
    public void RationalIdentities()
    {
        for (var n = -50; n <= 50; n++)
        for (var d = 1; d <= 50; d++)
        {
            var value = new Rational(n, d);
            Assert.Equal(new Rational(n, 1), value * new Rational(d, 1));
            Assert.Equal(new Rational(0, 1), value - value);
        }
    }
}
