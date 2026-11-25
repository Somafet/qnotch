using System.Globalization;
using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class ElectricalTests
{
    private static LineResult Last(string source)
    { var result = SheetEvaluator.Evaluate(source)[^1]; Assert.Null(result.Error); return result; }
    private static Rational Fraction(string text)
    { var parts = text.Split('/'); return new(BigInteger.Parse(parts[0], CultureInfo.InvariantCulture), parts.Length == 1 ? BigInteger.One : BigInteger.Parse(parts[1], CultureInfo.InvariantCulture)); }
    public static IEnumerable<object[]> OracleCases()
    {
        using var stream = typeof(ElectricalTests).Assembly.GetManifestResourceStream("Calc.ElectricalOracle")!;
        using var doc = JsonDocument.Parse(stream);
        return doc.RootElement.GetProperty("cases").EnumerateArray().Select(row => new object[] { row.GetRawText() }).ToArray();
    }
    [Theory, MemberData(nameof(OracleCases))]
    public void IndependentManufacturerTableAndNetworkOracle(string json)
    {
        using var doc = JsonDocument.Parse(json); var row = doc.RootElement;
        var value = Last(row.GetProperty("source").GetString()!).Value!.Value;
        if (row.GetProperty("kind").GetString() == "parallel")
        {
            Assert.Equal(Fraction(row.GetProperty("ohms").GetString()!), value.Number.Exact.Rational);
            Assert.Equal(row.GetProperty("unitful").GetBoolean(), value.Number.Unit is not null);
        }
        else
        {
            Assert.Equal(SheetValueKind.Resistor, value.Kind); var resistor = value.Resistor;
            Assert.Equal(Fraction(row.GetProperty("ohms").GetString()!), resistor.NominalOhms);
            Assert.Equal(Fraction(row.GetProperty("tolerance").GetString()!), resistor.Tolerance);
            Assert.Equal(Fraction(row.GetProperty("minimum").GetString()!), resistor.MinimumOhms);
            Assert.Equal(Fraction(row.GetProperty("maximum").GetString()!), resistor.MaximumOhms);
            Assert.Equal(row.GetProperty("digits").GetInt32(), resistor.SignificantDigits);
            Assert.Equal(row.GetProperty("colors").GetBoolean(), resistor.ShowColors);
            Assert.Equal(row.GetProperty("bands").EnumerateArray().Select(x => x.GetString()!), resistor.Bands);
            Assert.Equal(resistor.NominalOhms, Last(value.CopyText).Value!.Value.Resistor.NominalOhms);
            Assert.Equal(resistor.Tolerance, Last(value.CopyText).Value!.Value.Resistor.Tolerance);
        }
    }
    [Theory]
    [InlineData("12 V / 4 ohm", "3 A")]
    [InlineData("12 V * 2 A", "24 W")]
    [InlineData("2 A * 4 ohm", "8 V")]
    [InlineData("12 V / 2 A", "6 ohm")]
    [InlineData("10k || 4.7k", "3197.2789")]
    [InlineData("100 ohm || 100 ohm || 100 ohm", "33.3333 ohm")]
    [InlineData("1 kohm || 1000 ohm", "0.5 kohm")]
    [InlineData("parallel([100,200,300])", "54.5455")]
    [InlineData("parallel(5)", "5")]
    [InlineData("0 ohm || 100 ohm", "0 ohm")]
    [InlineData("10+10||10", "15")]
    [InlineData("10||10*2", "6.6667")]
    [InlineData("(10+10)||10", "6.6667")]
    [InlineData("brown black red gold", "1 kohm ±5%")]
    [InlineData("red orange violet black brown", "237 ohm ±1%")]
    [InlineData("green blue yellow gold", "560 kohm ±5%")]
    [InlineData("brown black silver silver", "0.1 ohm ±10%")]
    [InlineData("BROWN BLACK RED GOLD", "1 kohm ±5%")]
    [InlineData("grey red brown gold", "820 ohm ±5%")]
    [InlineData("brown black red", "1 kohm ±20%")]
    [InlineData("4.7k in colors", "yellow violet red")]
    [InlineData("4700 ohm to colours", "yellow violet red")]
    [InlineData("resistorColors(123 ohm,1%)", "brown red orange black brown")]
    [InlineData("resistor(1000,5,3)", "1 kohm ±5%")]
    [InlineData("resistor(1000,5%) in colors", "brown black red gold")]
    [InlineData("r=brown black red gold\nr in ohm", "1000 ohm")]
    [InlineData("r=brown black red gold\n12 V/r", "0.012 A")]
    [InlineData("r=brown black red gold\nr+r", "2 kohm")]
    [InlineData("r=brown black red gold\nparallel(r,r)", "0.5 kohm")]
    [InlineData("r=brown black red gold\nmean([r,r])", "1 kohm")]
    [InlineData("f(x)=x||x\nf(100 ohm)", "50 ohm")]
    [InlineData("f()=brown black red gold\nf()", "1 kohm ±5%")]
    [InlineData("brown black red gold=7\nbrown black red gold+4", "11")]
    public void PublishedSyntaxAndNominalCompositions(string source, string expected) => Assert.Equal(expected, Last(source).Display);
    [Theory]
    [InlineData("black black red gold")][InlineData("gold black red gold")][InlineData("brown silver red gold")]
    [InlineData("brown black red black")][InlineData("brown black red orange")][InlineData("brown black red white")]
    [InlineData("brown black black red brown blue")][InlineData("resistor(0)")][InlineData("resistor(-1)")]
    [InlineData("resistor(1.2345 ohm,5%)")][InlineData("resistorColors(123 ohm)")][InlineData("resistor(100 ohm,3%)")]
    [InlineData("resistor(100 ohm,0%)")][InlineData("resistor(100 ohm,20%,3)")][InlineData("resistor(100 ohm,5%,4)")]
    [InlineData("resistor(100 ohm,5%,2%)")][InlineData("resistor(1 m)")][InlineData("resistor(1 USD)")]
    [InlineData("resistor(100%)")][InlineData("resistor(sqrt(2) ohm)")][InlineData("resistor(100 ohm,5 ohm)")]
    [InlineData("parallel()")][InlineData("parallel([])")][InlineData("parallel(-1,0)")][InlineData("parallel(0,-1)")]
    [InlineData("1 m||2 m")][InlineData("1 ohm||2")][InlineData("1%||2%")][InlineData("today||2")]
    [InlineData("1 USD||2 USD")][InlineData("1|||2")][InlineData("resistorColors()")]
    public void AmbiguousMarkingsUnsupportedProfilesAndInvalidNetworksFail(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);
    [Fact]
    public void NominalUseNeverImpliesTolerancePropagation()
    {
        foreach (var operation in new[] { "r+r", "12 V/r", "parallel(r,r)", "mean([r,r])", "r in ohm", "r to nearest 10 ohm", "-r", "double r" })
        {
            var result = Last("r=brown black red gold\n" + operation);
            Assert.Contains(result.Explanation, step => step.Assumption?.Contains("tolerance intervals are not propagated") == true);
        }
        var mark = Last("brown black red gold");
        Assert.Contains(mark.Explanation, step => step.Assumption?.Contains("950–1050 ohm") == true);
        Assert.Contains(mark.Explanation, step => step.Assumption?.Contains(ResistorColorCatalog.RuleId) == true);
    }
    [Fact]
    public void MarkingsAndCopiesAreImmutableTypedAndComplete()
    {
        var resistor = Last("resistor(237 ohm,1%,3)").Value!.Value.Resistor;
        Assert.Throws<NotSupportedException>(() => ((IList<string>)resistor.Bands)[0] = "white");
        Assert.Equal(resistor, Last(new SheetValue(resistor).CopyText).Value!.Value.Resistor);
        Assert.NotEqual(resistor, Last("resistor(237 ohm,2%,3)").Value!.Value.Resistor);
        Assert.Equal(12, ResistorColorCatalog.Colors.Count);
        Assert.Equal(Enumerable.Range(0, 10), ResistorColorCatalog.Colors.Where(color => color.Digit is not null).Select(color => color.Digit!.Value));
        Assert.Equal(Enumerable.Range(-2, 12), ResistorColorCatalog.Colors.Select(color => color.MultiplierExponent).Order());
    }
    [Fact]
    public void IndependentCircuitIdentitiesRetainExactUnderlyingValues()
    {
        var random = new Random(90926);
        for (var i = 0; i < 100; i++)
        {
            var a = random.Next(1, 10000); var b = random.Next(1, 10000); var c = random.Next(1, 10000);
            var setup = $"a={a}\nb={b}\nc={c}\n";
            Assert.Equal("0", Last(setup + "(a||b)-(b||a)").Display);
            Assert.Equal("0", Last(setup + "((a||b)||c)-(a||(b||c))").Display);
            Assert.Equal("0", Last(setup + "(2*a||2*b)-2*(a||b)").Display);
            Assert.Equal(new Rational(a, 2), Last(setup + "a||a").Value!.Value.Exact.Rational);
            var network = Last(setup + "a||b").Value!.Value.Exact.Rational;
            Assert.True(network.Numerator.Sign > 0); Assert.True((new Rational(Math.Min(a, b), 1) - network).Numerator.Sign > 0);
        }
        Assert.Equal(new Rational(470000, 147), Last("10k||4.7k").Value!.Value.Scalar);
    }
    [Fact]
    public void ShapeCancellationAndSharedBudgetsBoundNetworks()
    {
        var branches = "[" + string.Join(',', Enumerable.Repeat("1", 1024)) + "]";
        Assert.Equal(new Rational(1, 1024), Last("parallel(" + branches + ")").Value!.Value.Scalar);
        var source = "r=" + branches + "\n" + string.Join('\n', Enumerable.Repeat("parallel(r)", 150));
        Assert.Throws<SheetComputationLimitException>(() => SheetEvaluator.Evaluate(source));
        Assert.NotNull(SheetEvaluator.Evaluate("parallel([" + string.Join(',', Enumerable.Repeat("1", 1025)) + "])")[0].Error);
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("parallel(" + branches + ")", cancelled.Token));
        Assert.Equal("0", Last("parallel(0,1/(10^1000),1/(10^999+1),1/(10^998+3))").Display);
        Assert.NotNull(SheetEvaluator.Evaluate("parallel(0,1/(10^1000),-1)")[0].Error);
    }
    [Fact]
    public void SavedFunctionsCacheDependenciesAndContextsStayStatic()
    {
        var library = new FunctionLibrary([new("divider", ["a", "b"], "a||b"), new("mark", ["x"], "resistorColors(x,1%,3)")]);
        var session = new SheetEvaluationSession(); const string source = "r=100 ohm\ns=r||r\ns\n7";
        session.EvaluateWithFunctions(source, library, []);
        var changed = session.EvaluateWithFunctions(source.Replace("100", "200"), library, []);
        Assert.Equal("100 ohm", changed.Results[2].Display); Assert.Equal(1, session.LastStatistics.ParsedLines); Assert.Equal(1, session.LastStatistics.ReusedResults);
        var again = session.EvaluateWithFunctions(source.Replace("100", "200"), library, [], context: new EvaluationContext(new DateOnly(2040, 1, 1), DateTimeOffset.UtcNow));
        Assert.Equal(4, session.LastStatistics.ReusedResults); Assert.False(again.UsesCurrentDate); Assert.False(again.UsesCurrentInstant); Assert.False(again.UsesCurrencyRates);
        Assert.Equal("50 ohm", session.EvaluateWithFunctions("divider(100 ohm,100 ohm)", library, []).Results[0].Display);
        Assert.Equal("brown red orange black brown", session.EvaluateWithFunctions("mark(123 ohm)", library, []).Results[0].Display);
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("parallel", ["x"], "x")]));
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("wrong", ["x"], "resistor(x,1,2,3)")]));
        Assert.All(SheetEvaluator.Evaluate("a=b||1\nb=a||1"), result => Assert.Equal("Circular dependency", result.Error));
    }
    [Fact]
    public void ApproximateNetworksKeepTheirProvenanceAndCannotInventColorCodes()
    {
        const string setup = "x=-fv(1%/12,1200,0,1)\n";
        var result = Last(setup + "x||1"); Assert.True(result.Value!.Value.Number.IsApproximate);
        Assert.Contains(result.Explanation, step => step.Assumption?.Contains("Approximate") == true);
        Assert.NotNull(SheetEvaluator.Evaluate(setup + "resistorColors(x)")[^1].Error);
    }
}
