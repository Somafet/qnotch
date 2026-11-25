using System.Globalization;
using System.Text;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class LocalizedKeywordTests
{
    public static IEnumerable<object[]> Fixtures()
    {
        using var stream = typeof(LocalizedKeywordTests).Assembly.GetManifestResourceStream("Calc.LocalizedFixtures")!;
        using var document = JsonDocument.Parse(stream);
        return document.RootElement.GetProperty("cases").EnumerateArray().Select(item => new object[]
        { item.GetProperty("language").GetString()!, item.GetProperty("source").GetString()!, item.GetProperty("expected").GetString()! }).ToArray();
    }
    [Theory]
    [MemberData(nameof(Fixtures))]
    public void IndependentArithmeticFixtures(string language, string source, string expected)
    {
        Assert.NotEmpty(language);
        var results = SheetEvaluator.Evaluate(source);
        Assert.All(results, result => Assert.Null(result.Error));
        Assert.Equal(expected, results[^1].Display);
    }
    [Fact]
    public void CatalogExplicitlyCoversNineLanguagesAndCurrentRoles()
    {
        using var stream = typeof(SheetEvaluator).Assembly.GetManifestResourceStream("Calc.LanguageKeywords")!;
        using var document = JsonDocument.Parse(stream);
        Assert.Equal(1, document.RootElement.GetProperty("version").GetInt32());
        var languages = document.RootElement.GetProperty("languages").EnumerateArray().ToArray();
        Assert.Equal(new[] { "en", "ro", "de", "fr", "es", "it", "ja", "zh-Hans", "ko" }, languages.Select(language => language.GetProperty("code").GetString()));
        foreach (var language in languages)
            foreach (var role in new[] { "Of", "Sum", "Average", "Half", "Double", "To", "Nearest" })
                Assert.NotEmpty(language.GetProperty("keywords").GetProperty(role).EnumerateArray());
    }
    [Fact]
    public void NamesAndCallsAreNotTranslatedOrSplit()
    {
        var source = "de=3\nmoyenne=7\n平均費用=8\n半分合成=9\nの金額=11\nde+1\nmoyenne\n平均費用+1\n半分合成+1\nの金額+1\n半分合成Fn(x)=x+2\nf(x)=半分合成Fn(x)\nf(3)\nsomme(x)=x+3\nsomme (4)";
        var results = SheetEvaluator.Evaluate(source);
        Assert.All(results, result => Assert.Null(result.Error));
        Assert.Equal("4", results[5].Display); Assert.Equal("7", results[6].Display); Assert.Equal("9", results[7].Display);
        Assert.Equal("10", results[8].Display); Assert.Equal("12", results[9].Display);
        Assert.Equal("5", results[12].Display); Assert.Equal("7", results[14].Display);
    }
    [Fact]
    public void FunctionParametersAndCanonicalReceiptsRemainSourceBased()
    {
        var update = FunctionUpdate.Prepare("f(金額)=20%の金額\ng(半分合成)=半分合成+1", FunctionLibrary.Empty, []);
        var values = new SheetEvaluationSession().EvaluateWithFunctions("f(150)\ng(3)", update.Library, []).Results;
        Assert.Equal(new[] { "30", "4" }, values.Select(result => result.Display));
        var same = FunctionUpdate.Prepare("F(金額) = 20% の 金額\nG(半分合成) = 半分合成 + 1", update.Library, update.Receipts);
        Assert.False(same.HasChanges);
        var ordinary = FunctionUpdate.Prepare("f(de)=de+1", FunctionLibrary.Empty, []);
        Assert.False(FunctionUpdate.Prepare("F (DE) = DE + 1", ordinary.Library, ordinary.Receipts).HasChanges);
    }
    [Fact]
    public void TaggedLocalizedAggregatesDoNotDoubleCountAndInvalidateCorrectly()
    {
        var session = new SheetEvaluationSession();
        Assert.Equal("3", session.Evaluate("1 #x\n2 #x\n合計 #x\nsomme #x")[3].Display);
        Assert.Equal("7", session.Evaluate("1 #x\n2 #x\n合計 #x\nsomme #x\nsomme=7")[3].Display);
        var results = session.Evaluate("1 #x\n2 #x\n合計 #x\nsomme #x");
        Assert.Equal("3", results[3].Display); Assert.Equal(new[] { 0, 1 }, results[3].Dependencies);
    }
    [Fact]
    public void AccentedKeywordsAcceptCanonicalUnicodeCompositionWithoutRenamingIdentifiers()
    {
        var input = "jumătate din 10".Normalize(NormalizationForm.FormD);
        Assert.Equal("5", SheetEvaluator.Evaluate(input)[0].Display);
        var variable = "preț".Normalize(NormalizationForm.FormD);
        var results = SheetEvaluator.Evaluate($"{variable}=10\n{variable}+2");
        Assert.Equal("12", results[1].Display);
        Assert.NotNull(SheetEvaluator.Evaluate($"{variable}=10\npreț+2")[1].Error);
        var tag = "dépenses".Normalize(NormalizationForm.FormD);
        Assert.Equal("3", SheetEvaluator.Evaluate($"1 #{tag}\n2 #{tag}\nsomme #{tag}")[2].Display);
    }
    [Fact]
    public void SeededMixedLanguagePercentagesMatchIndependentDecimalArithmetic()
    {
        var random = new Random(5083);
        string[] operators = ["of", "din", "von", "de", "di", "の", "的", "의"];
        for (var trial = 0; trial < 500; trial++)
        {
            var percent = random.Next(-100, 101); var amount = random.Next(-10000, 10001);
            var source = $"{percent}% {operators[random.Next(operators.Length)]} ({amount})";
            var result = SheetEvaluator.Evaluate(source)[0];
            Assert.Null(result.Error);
            Assert.Equal(Rational.Parse((percent * amount / 100m).ToString(CultureInfo.InvariantCulture)), result.Value!.Value.Scalar);
        }
    }
    [Theory]
    [InlineData("2.675保留0位有效数字")]
    [InlineData("2.675を小数点以下-1桁")]
    [InlineData("2.675소수점257자리")]
    [InlineData("20% de typo")]
    [InlineData("150の間違い")]
    [InlineData("2.675を2桁")]
    [InlineData("2.675소수점2")]
    [InlineData("12.37 la cel mai apropiat multiplu de 0")]
    public void InvalidLocalizedInputNeverPublishesANumber(string source)
    {
        var result = SheetEvaluator.Evaluate(source)[0];
        Assert.Null(result.Value); Assert.NotNull(result.Error);
    }
    [Fact]
    public void UnspacedKeywordStreamsAndCancellationStayBounded()
    {
        Assert.NotNull(SheetEvaluator.Evaluate(string.Concat(Enumerable.Repeat("半分の", 5000)) + "150")[0].Error);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("2.675を小数点以下2桁", cancellation.Token));
    }
    [Fact]
    public void OnlyCompleteConversationalPhrasesChangeLeadingLabelHandling()
    {
        Assert.Equal("10", SheetEvaluator.Evaluate("das 10")[0].Display);
        Assert.Equal("10", SheetEvaluator.Evaluate("la 10")[0].Display);
        Assert.NotNull(SheetEvaluator.Evaluate("Budget das doppelte 10")[0].Error);
        Assert.Equal("20", SheetEvaluator.Evaluate("\"Budget\" das doppelte 10")[0].Display);
    }
}
