using System.Globalization;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class UnitTests
{
    public static IEnumerable<object[]> Fixtures()
    {
        using var stream = typeof(UnitTests).Assembly.GetManifestResourceStream("Calc.UnitFixtures")!;
        using var json = JsonDocument.Parse(stream);
        return json.RootElement.GetProperty("cases").EnumerateArray().Select(item => new object[]
            { item.GetProperty("source").GetString()!, item.GetProperty("expected").GetString()! }).ToArray();
    }
    [Theory]
    [MemberData(nameof(Fixtures))]
    public void IndependentlyDefinedExactFixtures(string source, string expected)
    {
        var results = SheetEvaluator.Evaluate(source);
        Assert.All(results, result => Assert.Null(result.Error));
        Assert.Equal(expected, results[^1].Display);
        var pasted = SheetEvaluator.Evaluate(results[^1].Display)[0];
        Assert.Null(pasted.Error); Assert.Equal(results[^1].Value, pasted.Value);
    }
    [Fact]
    public void EveryCatalogEntryParsesAndRoundTripsWithItsDeclaredDimension()
    {
        Assert.Equal(new NumericValue(new Rational(0, 1)), default(NumericValue));
        Assert.Equal(219, UnitCatalog.Units.Count);
        Assert.Equal(219, UnitCatalog.Units.Select(unit => unit.Id).Distinct().Count());
        foreach (var unit in UnitCatalog.Units)
        {
            Assert.StartsWith("https://", unit.Source);
            var result = SheetEvaluator.Evaluate("1 " + unit.Symbol)[0];
            Assert.Null(result.Error); Assert.Equal(unit.Dimension, result.Value!.Value.Unit!.Dimension);
            Assert.Equal(unit.Factor + unit.Offset, result.Value.Value.Exact.Rational);
            Assert.Equal(result.Value, SheetEvaluator.Evaluate(result.Display)[0].Value);
            Assert.Throws<ArithmeticException>(() => result.Value.Value.Scalar);
        }
    }
    [Fact]
    public void SymbolsKeepCaseAndFunctionReceiptsCannotReuseADifferentUnit()
    {
        var first = FunctionUpdate.Prepare("f()=2 mV", FunctionLibrary.Empty, []);
        var changed = new SheetEvaluationSession().EvaluateWithFunctions("f()=2 MV\nf() in V", first.Library, first.Receipts);
        Assert.True(changed.Functions.HasChanges); Assert.Equal("2000000 V", changed.Results[1].Display);
        var byteFunction = FunctionUpdate.Prepare("g()=2 B", FunctionLibrary.Empty, []);
        Assert.False(FunctionUpdate.Prepare("G()=2 bytes", byteFunction.Library, byteFunction.Receipts).HasChanges);
        var parameter = FunctionUpdate.Prepare("f(m)=m+1", FunctionLibrary.Empty, []);
        Assert.False(FunctionUpdate.Prepare("F(M)=M+1", parameter.Library, parameter.Receipts).HasChanges);
        Assert.Equal("3", SheetEvaluator.Evaluate("m(x)=x+1\nm(2)")[1].Display);
    }
    [Fact]
    public void NamesStayNamesAndConversionTargetsUseTheirUnitRole()
    {
        var result = SheetEvaluator.Evaluate("m=7\n2*m\n2 metres\n2 ft in m\n2m");
        Assert.Equal("14", result[1].Display); Assert.Equal("2 m", result[2].Display); Assert.Equal("0.6096 m", result[3].Display);
        Assert.NotNull(result[4].Error);
    }
    [Fact]
    public void SeededIndependentLengthAndAreaDefinitionsHold()
    {
        var random = new Random(3011);
        for (var trial = 0; trial < 300; trial++)
        {
            var feet = random.Next(-10000,10001); var inches = random.Next(0,12);
            var source = $"({feet} ft + {inches} in) in m";
            var answer = SheetEvaluator.Evaluate(source)[0];
            Assert.Null(answer.Error);
            Assert.Equal(new Rational(feet * 3048L + inches * 254L,10000), answer.Value!.Value.Exact.Rational);
            var square = SheetEvaluator.Evaluate($"({feet} ft)^2 in m^2")[0];
            Assert.Null(square.Error); Assert.Equal(new Rational((long)feet*feet*145161,1562500), square.Value!.Value.Exact.Rational);
        }
    }
    [Fact]
    public void SeededAffineConversionsAndDifferencesUseIndependentEquations()
    {
        for (var c = -273; c <= 300; c += 3)
        {
            var value = SheetEvaluator.Evaluate($"{c} °C in °F")[0];
            Assert.Null(value.Error);
            // Reparse output and convert back; independent coordinate formula checks the displayed value too.
            Assert.Equal($"{(c*9/5m+32).ToString(CultureInfo.InvariantCulture)} °F", value.Display);
            Assert.Equal($"{c} °C", SheetEvaluator.Evaluate(value.Display + " in °C")[0].Display);
        }
        Assert.Equal("10 deltaC", SheetEvaluator.Evaluate("30 °C - 68 °F")[0].Display);
    }
    [Fact]
    public void UnitMetadataInvalidatesDependentAndAggregateCaches()
    {
        var session = new SheetEvaluationSession(); session.Evaluate("x=1 m\nx in cm\n2 m #x\nx #x\nsum #x");
        var changed = session.Evaluate("x=1 ft\nx in cm\n2 m #x\nx #x\nsum #x");
        Assert.Equal("30.48 cm", changed[1].Display); Assert.Equal("2.3048 m", changed[4].Display);
        Assert.True(session.LastStatistics.ReusedResults > 0);
        Assert.Contains(changed[1].Explanation, step => step.Operation == "convert unit" && step.Assumption!.Contains("dimensions checked"));
        var failed = session.Evaluate("x=1 s\nx in cm\n2 m #x\nx #x\nsum #x");
        Assert.Null(failed[1].Value); Assert.Null(failed[4].Value);
    }
    [Theory]
    [InlineData("1 m + 1 s")]
    [InlineData("1 m in kg")]
    [InlineData("1 in nonsense")]
    [InlineData("sqrt(1 m)")]
    [InlineData("1 m^17")]
    [InlineData("1 m^1.5")]
    [InlineData("1 m^(")]
    [InlineData("1 m%")]
    [InlineData("1% m")]
    [InlineData("1 m!")]
    [InlineData("1 m to nearest 1")]
    [InlineData("1 m to nearest 1 s")]
    [InlineData("1 m to 1 m decimals")]
    [InlineData("20 °C + 10 °C")]
    [InlineData("2 * 10 °C")]
    [InlineData("10 K / 2")]
    [InlineData("-1 K")]
    [InlineData("-274 °C")]
    [InlineData("1 °C/s")]
    [InlineData("1 °C in deltaC")]
    [InlineData("10 deltaC - 10 °C")]
    [InlineData("1 °C #t\n2 °C #t\nsum #t")]
    [InlineData("1 m #t\n2 s #t\nsum #t")]
    [InlineData("1 m 2 s")]
    [InlineData("1 mb")]
    [InlineData("1 rad")]
    [InlineData("1 Gy in Sv")]
    [InlineData("1 Gy + 1 Sv")]
    [InlineData("(1 Gy in J/kg) in Sv")]
    [InlineData("1 Hz in Bq")]
    [InlineData("1 J/kg #x\n1 Gy #x\n1 Sv #x\nsum #x")]
    public void InvalidDomainsNeverLoseTheirUnits(string source)
    {
        var result = SheetEvaluator.Evaluate(source)[^1];
        Assert.Null(result.Value); Assert.NotNull(result.Error);
    }
}
