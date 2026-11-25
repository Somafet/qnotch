using Calc.Core;

namespace Calc.Core.Tests;

public class DefaultCurrencyTests
{
    private static CurrencyRateSnapshot Latest() => new("Test daily rates","EUR",new(2026,10,30),new(2026,10,30,17,0,0,TimeSpan.Zero),
        new Dictionary<string,Rational> { ["EUR"]=new(1,1),["USD"]=new(2,1),["RON"]=new(5,1) });
    private static EvaluationContext Context(string? display = "RON", bool rates = true) =>
        new(new(2026,10,31),CurrencyRates:rates ? new(Latest(),new Dictionary<DateOnly,CurrencyRateSnapshot>()) : CurrencyRateBook.Empty) { DisplayCurrency = display };
    private static string Shown(LineResult result) => ResultFormatter.Format(result,ResultFormat.Default);

    [Theory]
    [InlineData("800 usd", "2000 RON")]
    [InlineData("$10 + €2", "35 RON")]
    [InlineData("800 usd in eur", "400 EUR")]
    [InlineData("(800 usd in eur) * 2", "800 EUR")]
    [InlineData("50 ron", "50 RON")]
    [InlineData("100 eur in usd on 2024-01-01", "Historical currency rates unavailable for 2024-01-01")]
    [InlineData("800", "800")]
    public void PlainMoneyIsShownInTheDefaultCurrencyUnlessTheLineNamesItsTarget(string source,string expected)
    {
        var result = SheetEvaluator.Evaluate(source,context:Context())[^1];
        Assert.Equal(expected,result.Error ?? Shown(result));
    }

    [Fact]
    public void ConversionIsDisplayOnlySoReferencesKeepTheirCurrency()
    {
        var results = SheetEvaluator.Evaluate("x = 800 usd\nx + 1 usd\nx / 2 usd",context:Context());
        Assert.Equal("800 USD",results[0].Display); Assert.Equal("2000 RON",Shown(results[0]));
        Assert.Equal("801 USD",results[1].Value!.Value.Display); Assert.Equal("2002.5 RON",Shown(results[1]));
        Assert.Equal("400",Shown(results[2])); Assert.Null(results[2].Shown);
        Assert.Contains(results[0].Explanation,step => step.Operation == "show in default currency" && step.Assumption!.Contains("references keep USD"));
    }

    [Fact]
    public void NoDefaultOrMissingRatesLeaveTheOriginalAmount()
    {
        var off = SheetEvaluator.Evaluate("800 usd",context:Context(null))[0];
        Assert.Null(off.Shown); Assert.Equal("800 USD",Shown(off));
        var evaluation = new SheetEvaluationSession().EvaluateWithFunctions("800 usd",FunctionLibrary.Empty,[],context:Context(null));
        Assert.False(evaluation.UsesCurrencyRates); // No default currency: a plain amount needs no rates.
        var missing = new SheetEvaluationSession().EvaluateWithFunctions("800 usd",FunctionLibrary.Empty,[],context:Context(rates:false));
        Assert.Null(missing.Results[0].Error); Assert.Equal("800 USD",Shown(missing.Results[0]));
        Assert.True(missing.UsesCurrencyRates); // The host shows rate status and may refresh only under its existing consent.
    }

    [Fact]
    public void CachedResultsFollowDefaultCurrencyAndRateChanges()
    {
        var session = new SheetEvaluationSession();
        Assert.Equal("800 USD",Shown(session.Evaluate("800 usd",context:Context(null))[0]));
        Assert.Equal("2000 RON",Shown(session.Evaluate("800 usd",context:Context())[0]));
        Assert.Equal("400 EUR",Shown(session.Evaluate("800 usd",context:Context("EUR"))[0]));
        Assert.Equal("800 USD",Shown(session.Evaluate("800 usd",context:Context(rates:false))[0]));
        Assert.Equal("2000 RON",Shown(session.Evaluate("800 usd",context:Context())[0]));
        Assert.Equal("5",Shown(session.Evaluate("5",context:Context("EUR"))[0]));
    }
}
