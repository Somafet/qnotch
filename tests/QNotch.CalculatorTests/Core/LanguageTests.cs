using Calc.Core;

namespace Calc.Core.Tests;

public class LanguageTests
{
    [Theory]
    [InlineData("2^3^2", "512")]
    [InlineData("-2^2", "-4")]
    [InlineData("(-2)^2", "4")]
    [InlineData("2^-3", "0.125")]
    [InlineData("5! + 0!", "121")]
    [InlineData("sqrt(81/16)", "2.25")]
    [InlineData("15%", "15%")]
    [InlineData("150 + 20%", "180")]
    [InlineData("150 - 10%", "135")]
    [InlineData("20% of 150", "30")]
    [InlineData("50 is what % of 200", "25%")]
    [InlineData("30 is 15% of what", "200")]
    [InlineData("120 is 20% off what", "150")]
    [InlineData("change(80,100)", "25%")]
    [InlineData("change(100,80)", "-20%")]
    [InlineData("margin(80,100)", "20%")]
    [InlineData("markup(80,100)", "25%")]
    [InlineData("10% + 5%", "15%")]
    [InlineData("12%/3", "4%")]
    [InlineData("100 + (10% * 2)", "100.2")]
    [InlineData("\"Lunch = // #no\" 12.50 + 2.50 #food", "15")]
    [InlineData("Rent 1200 #home", "1200")]
    public void ExactCases(string source, string expected)
    {
        var result = SheetEvaluator.Evaluate(source)[0];
        Assert.Null(result.Error); Assert.Equal(expected, result.Display);
        Assert.NotEmpty(result.Explanation);
    }
    [Fact]
    public void PercentageVariablesRemainTyped()
    {
        var result = SheetEvaluator.Evaluate("price = 1200\ndiscount = 15%\nprice - discount\nL3 * 2\nprev / 4");
        Assert.Equal(new[] { "1200", "15%", "1020", "2040", "510" }, result.Select(v => v.Display));
        Assert.True(result[1].Value!.Value.IsPercentage);
        Assert.Contains(result[2].Explanation, s => s.Assumption?.Contains("relative") == true);
    }
    [Fact]
    public void MultiwordForwardAndReassignedVariables()
    {
        var result = SheetEvaluator.Evaluate("total cost = unit price * 3\nunit price = 7\nunit price = unit price + 1\ntotal cost + unit price");
        Assert.Equal(new[] { "21", "7", "8", "29" }, result.Select(v => v.Display));
        Assert.Equal(new[] { 1 }, result[0].Dependencies);
    }
    [Fact]
    public void MultiwordVariablesCanContainOperatorWords()
    {
        var results = SheetEvaluator.Evaluate("cost of goods=80\nthis is price=100\nthis is price - cost of goods\n20% of cost of goods");
        Assert.Equal(new[] { "80", "100", "20", "16" }, results.Select(r => r.Display));
    }
    [Fact]
    public void ForwardLineReferencesAndCycles()
    {
        var result = SheetEvaluator.Evaluate("L3 + 1\nL1 * 2\n5\nL5\nL4\nL4 + 1");
        Assert.Equal("6", result[0].Display); Assert.Equal("12", result[1].Display);
        Assert.All(result.Skip(3), r => Assert.Equal("Circular dependency", r.Error));
        Assert.Equal("Circular dependency", SheetEvaluator.Evaluate("a = a + 1")[0].Error);
        Assert.Equal("Dependency L1 unavailable", SheetEvaluator.Evaluate("# Heading\nprev+1")[1].Error);
    }
    [Fact]
    public void BlocksAndWholeSheetTagTotalsExcludeAggregateResults()
    {
        var result = SheetEvaluator.Evaluate("Rent 1200 #home\nInternet 40 #home\nsum\naverage\n\n# Travel\nTrip 600 #travel\nsum #home\nDinner 60 #home\nsum #home");
        Assert.Equal("1240", result[2].Display); Assert.Equal("620", result[3].Display);
        Assert.Equal("1300", result[7].Display); Assert.Equal("1300", result[9].Display);
        Assert.Equal(new[] { 0, 1, 8 }, result[7].Dependencies);
    }
    [Fact]
    public void ProseAndCommentsAreBlankButMisspelledOperandsAreErrors()
    {
        var result = SheetEvaluator.Evaluate("Budget notes\n# Week\n\"comment only\"\na = 2\na 3\nmisspelled + 3\n// comment");
        Assert.All(result.Take(3), r => { Assert.Null(r.Value); Assert.Null(r.Error); });
        Assert.NotNull(result[4].Error); Assert.NotNull(result[5].Error); Assert.Null(result[6].Error);
    }
    [Theory]
    [InlineData("sqrt(-1 m^2)")]
    [InlineData("2^(1/3)")]
    [InlineData("2^2048")]
    [InlineData("(-1)!")]
    [InlineData("501!")]
    [InlineData("1/0")]
    [InlineData("120 is 100% off what")]
    [InlineData("share(1,0)")]
    [InlineData("prev")]
    [InlineData("L0")]
    [InlineData("\"unclosed")]
    [InlineData("sum #one #two")]
    public void DomainAndSyntaxFailuresAreExplicit(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[0].Error);
    [Fact]
    public void DeepDependencyChainsDoNotUseCallStack()
    {
        var source = "1\n" + string.Join('\n', Enumerable.Repeat("prev+1", 9999));
        Assert.Equal("10000", SheetEvaluator.Evaluate(source)[^1].Display);
    }
    [Fact]
    public void TotalsDoNotSilentlyExcludeMalformedCalculations()
    {
        var results = SheetEvaluator.Evaluate("10 #cost\n2+ #cost\nsum #cost\nsum");
        Assert.Equal("Dependency L2 unavailable", results[2].Error);
        Assert.Equal("Dependency L2 unavailable", results[3].Error);
    }
    [Fact]
    public void DefaultRationalIsCanonicalZero()
    {
        Assert.Equal(new Rational(0, 1), default(Rational));
        Assert.Equal("0", default(Rational).ToString());
    }
    [Fact]
    public void LongLabelsAndIdentifierErrorsStayBounded()
    {
        var label = string.Join(' ', Enumerable.Repeat("word", 2000));
        Assert.Equal("2", SheetEvaluator.Evaluate(label + " 2")[0].Display);
        Assert.Equal("Identifier limit exceeded", SheetEvaluator.Evaluate(label + "+2")[0].Error);
        Assert.Throws<FormatException>(() => Rational.Parse("1.2.3"));
    }
    [Fact]
    public void ParserFuzzAndAggregateExpansionAreBounded()
    {
        var random = new Random(719);
        const string alphabet = "0123ab +-*^!%()/\"#=_.,";
        for (var i = 0; i < 500; i++)
        {
            var source = new string(Enumerable.Range(0, random.Next(1, 120)).Select(_ => alphabet[random.Next(alphabet.Length)]).ToArray());
            var result = SheetEvaluator.Evaluate(source)[0];
            Assert.True(result.Explanation.Count <= 64);
            Assert.True(result.Display.Length <= 2048);
        }
        var many = SheetEvaluator.Evaluate(string.Join('\n', Enumerable.Repeat("1 #x", 1000).Concat(Enumerable.Repeat("sum #x", 1000))));
        Assert.Contains(many, r => r.Error == "Sheet dependency limit exceeded");
    }
}
