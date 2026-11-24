using System.Globalization;
using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class NumberLanguageTests
{
    public static IEnumerable<object[]> Fixtures()
    {
        using var stream = typeof(NumberLanguageTests).Assembly.GetManifestResourceStream("Calc.NumberLanguageFixtures")!;
        using var document = JsonDocument.Parse(stream);
        return document.RootElement.GetProperty("cases").EnumerateArray().Select(item => new object[]
        {
            item.GetProperty("input").GetString()!, item.GetProperty("expected").GetString()!, item.TryGetProperty("error", out var error) && error.GetBoolean()
        }).ToArray();
    }
    [Theory]
    [MemberData(nameof(Fixtures))]
    public void IndependentExactFixtures(string source, string expected, bool error)
    {
        var result = SheetEvaluator.Evaluate(source)[0];
        Assert.Equal(expected, result.Display);
        if (error) { Assert.Null(result.Value); Assert.NotNull(result.Error); }
        else { Assert.Null(result.Error); Assert.NotNull(result.Value); }
    }
    [Theory]
    [InlineData("5mx")]
    [InlineData("5b")]
    [InlineData("5 M")]
    [InlineData("5 Bx")]
    [InlineData("5 k")]
    [InlineData("5kmx")]
    [InlineData("5mbps")]
    [InlineData("5kWhx")]
    [InlineData("5monthsx")]
    [InlineData("5millionaires")]
    [InlineData("5million2")]
    [InlineData("5kk")]
    [InlineData("5k2")]
    [InlineData("2kM")]
    [InlineData("2%k")]
    [InlineData("1万2万")]
    [InlineData("1万2億")]
    [InlineData("1億10000万")]
    [InlineData("2万30000")]
    [InlineData("2.5万3000")]
    [InlineData("2万3k")]
    [InlineData("2万 3000")]
    [InlineData("2万億")]
    [InlineData("double typo")]
    [InlineData("half of")]
    [InlineData("Budget double 5")]
    [InlineData("double(5)")]
    public void AmbiguousMalformedAndUnknownFormsDoNotPublishANumber(string source)
    {
        var result = SheetEvaluator.Evaluate(source)[0];
        Assert.Null(result.Value); Assert.NotNull(result.Error);
    }
    [Fact]
    public void DeclaredNamesAndExistingFunctionCallsRetainTheirMeaning()
    {
        var source = "double price=7\nhalf=3\nM=4\n万事=9\ndouble price\nhalf+1\n2*M\n万事+1\ndouble(x)=x+1\ndouble (5)\nhalf(x)=x+3\nhalf(5)\n2M";
        var results = SheetEvaluator.Evaluate(source);
        Assert.Equal("7", results[4].Display); Assert.Equal("4", results[5].Display);
        Assert.Equal("8", results[6].Display); Assert.Equal("10", results[7].Display);
        Assert.Equal("6", results[9].Display); Assert.Equal("8", results[11].Display);
        Assert.Equal("2000000", results[12].Display);
        Assert.Equal("Unknown function: double", SheetEvaluator.Evaluate("double(5)")[0].Error);
    }
    [Fact]
    public void VariablesReferencesFunctionScopeAndPercentagesWorkTogether()
    {
        var source = "cost=2.5k\ndouble cost\ncut(x)=half x\ncut(L2)\np=10%\ntwice p\n100+L6\n\"Budget\" double 2M";
        var results = SheetEvaluator.Evaluate(source);
        Assert.Equal(new[] { "2500", "5000", "", "2500", "10%", "20%", "120", "4000000" }, results.Select(result => result.Display));
        Assert.Equal(new[] { 0 }, results[1].Dependencies); Assert.Equal(new[] { 1 }, results[3].Dependencies);
        Assert.True(results[5].Value!.Value.IsPercentage);
        Assert.Contains(results[1].Explanation, step => step.Operation == "scale by double" && step.Operands[1] == "2");
    }
    [Fact]
    public void FunctionReceiptsPreserveSignificantWhitespaceAndOldCanonicalKeys()
    {
        var ordinary = FunctionUpdate.Prepare("f(x)=x+1", FunctionLibrary.Empty, []);
        Assert.False(FunctionUpdate.Prepare("F ( X ) = X + 1", ordinary.Library, ordinary.Receipts).HasChanges);
        var shortForm = FunctionUpdate.Prepare("f()=2M", FunctionLibrary.Empty, []);
        var invalidSpace = new SheetEvaluationSession().EvaluateWithFunctions("f()=2 M\nf()", shortForm.Library, shortForm.Receipts);
        Assert.NotNull(invalidSpace.Results[0].Error); Assert.Null(invalidSpace.Results[1].Value);
        var changedUnit = new SheetEvaluationSession().EvaluateWithFunctions("f()=2m\nf()", shortForm.Library, shortForm.Receipts);
        Assert.Null(changedUnit.Results[0].Error); Assert.Equal("2 m", changedUnit.Results[1].Display);
        Assert.True(changedUnit.Functions.HasChanges);
        var cjk = FunctionUpdate.Prepare("g()=2万3000", FunctionLibrary.Empty, []);
        var invalidGroupSpace = new SheetEvaluationSession().EvaluateWithFunctions("g()=2万 3000\ng()", cjk.Library, cjk.Receipts);
        Assert.NotNull(invalidGroupSpace.Results[0].Error); Assert.Null(invalidGroupSpace.Results[1].Value);
        Assert.Equal("23000", new SheetEvaluationSession().EvaluateWithFunctions("g()", cjk.Library, []).Results[0].Display);
    }
    [Fact]
    public void SeededCoefficientsMatchIndependentIntegerScaling()
    {
        var random = new Random(5541);
        (string Suffix, int Exponent)[] factors = [("k", 3), ("M", 6), ("B", 9), (" thousand", 3), (" million", 6), (" billion", 9), ("万", 4), ("億", 8), ("亿", 8), ("만", 4), ("억", 8)];
        for (var sample = 0; sample < 1000; sample++)
        {
            var numerator = random.Next(-100_000_000, 100_000_001); var factor = factors[random.Next(factors.Length)];
            var coefficient = (numerator / 1000m).ToString(CultureInfo.InvariantCulture);
            var expected = new Rational(new BigInteger(numerator) * BigInteger.Pow(10, factor.Exponent), 1000);
            var actual = SheetEvaluator.Evaluate(coefficient + factor.Suffix)[0];
            Assert.Null(actual.Error); Assert.Equal(expected, actual.Value!.Value.Scalar);
        }
    }
    [Fact]
    public void CjkCompoundNumbersMatchIndependentPlaceValues()
    {
        var random = new Random(8029);
        foreach (var (high, low) in new[] { ("億", "万"), ("亿", "万"), ("억", "만") })
            for (var sample = 0; sample < 100; sample++)
            {
                var a = random.Next(1, 500); var b = random.Next(0, 10000); var c = random.Next(0, 10000);
                var result = SheetEvaluator.Evaluate($"{a}{high}{b}{low}{c}")[0];
                Assert.Null(result.Error);
                Assert.Equal(new Rational(new BigInteger(a) * 100_000_000 + b * 10000 + c, 1), result.Value!.Value.Scalar);
            }
    }
    [Fact]
    public void KeywordBindingChangesInvalidateTheCurrentSheetCache()
    {
        var session = new SheetEvaluationSession();
        Assert.Equal("10", session.Evaluate("double 5\nnotes")[0].Display);
        Assert.NotNull(session.Evaluate("double 5\ndouble=3")[0].Error);
        Assert.Equal("10", session.Evaluate("double 5\nnotes")[0].Display);
        Assert.Equal("20%", session.Evaluate("p=10%\ntwice p")[1].Display);
        Assert.Equal("30%", session.Evaluate("p=15%\ntwice p")[1].Display);
    }
    [Fact]
    public void ExpansionAndMalformedTokenStreamsStayBounded()
    {
        var result = SheetEvaluator.Evaluate(string.Concat(Enumerable.Repeat("double ", 100)) + "1")[0];
        Assert.Equal("Expression depth limit exceeded", result.Error);
        Assert.NotNull(SheetEvaluator.Evaluate("1" + string.Concat(Enumerable.Repeat("万1", 2000)))[0].Error);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("2億300万4000", cancellation.Token));
        var random = new Random(7755);
        string[] pieces = ["2", "万", "億", "亿", "만", "억", "k", "M", "m", "B", "double ", "half of ", "twice ", "+", "-", "%", "(", ")", " "];
        for (var sample = 0; sample < 500; sample++)
        {
            var text = string.Concat(Enumerable.Range(0, random.Next(1, 40)).Select(_ => pieces[random.Next(pieces.Length)]));
            var item = SheetEvaluator.Evaluate(text)[0];
            Assert.True(item.Display.Length <= 2048); Assert.True(item.Explanation.Count <= 64);
        }
    }
}
