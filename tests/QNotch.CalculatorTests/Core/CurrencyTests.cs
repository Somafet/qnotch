using Calc.Core;

namespace Calc.Core.Tests;

public class CurrencyTests
{
    private static CurrencyRateSnapshot Latest(int usd=2) => new("Test daily rates","EUR",new(2026,10,30),new(2026,10,30,17,0,0,TimeSpan.Zero),
        new Dictionary<string,Rational> { ["EUR"]=new(1,1),["USD"]=new(usd,1),["GBP"]=new(1,2),["JPY"]=new(100,1),["RON"]=new(5,1) });
    private static CurrencyRateSnapshot Historical() => new("ECB via Frankfurter","EUR",new(2023,12,29),new(2026,10,31,0,0,0,TimeSpan.Zero),
        new Dictionary<string,Rational> { ["EUR"]=new(1,1),["USD"]=Rational.Parse("1.1050"),["GBP"]=Rational.Parse("0.86905"),["JPY"]=Rational.Parse("156.33") });
    private static EvaluationContext Context(int usd=2) => new(new(2026,10,31),CurrencyRates:new(Latest(usd),new Dictionary<DateOnly,CurrencyRateSnapshot>{[new(2024,1,1)]=Historical()}));
    private static LineResult Last(string source,EvaluationContext? context=null) => SheetEvaluator.Evaluate(source,context:context??Context())[^1];
    [Theory]
    [InlineData("100 usd", "100 USD")]
    [InlineData("$100", "100 USD")]
    [InlineData("US$100", "100 USD")]
    [InlineData("USD 100", "100 USD")]
    [InlineData("US dollars 100", "100 USD")]
    [InlineData("€100 in $", "200 USD")]
    [InlineData("100 usd in eur", "50 EUR")]
    [InlineData("49 usd + 19 eur in gbp", "21.75 GBP")]
    [InlineData("dinner=84 eur/3\ndinner in usd", "56 USD")]
    [InlineData("100 EUR+10%", "110 EUR")]
    [InlineData("100 EUR-10%", "90 EUR")]
    [InlineData("20% of 100 EUR", "20 EUR")]
    [InlineData("100 EUR/50 USD", "4")]
    [InlineData("20 USD/h * (9:15–17:40 - 45 min)", "153.33 USD")]
    [InlineData("20 USD/h * 8 h", "160 USD")]
    [InlineData("20 USD/h in EUR/h", "10 EUR/h")]
    [InlineData("20 USD/h in EUR/min", "0.17 EUR/min")]
    [InlineData("100 JPY in USD", "2 USD")]
    [InlineData("100 EUR in USD on 1 jan 2024", "110.5 USD")]
    [InlineData("100 USD + 100 EUR in USD on 2024-01-01", "210.5 USD")]
    [InlineData("f(x)=x+1 EUR\nf(2 USD) in USD on 2024-01-01", "3.11 USD")]
    [InlineData("f(x,y)=x+y\nf(100 EUR in USD on 2024-01-01, 2 USD)", "112.5 USD")]
    [InlineData("holidays=[]\n1 cup in ml", "236.5882365 mL")]
    [InlineData("1 CUP", "1 CUP")]
    public void MonetaryExamplesUseExactSnapshots(string source,string expected)
    {
        var result=Last(source); Assert.Null(result.Error); Assert.Equal(expected,result.Display);
    }
    [Fact]
    public void ConversionKeepsExactValuesInsteadOfRepeatedDisplayRounding()
    {
        var thirds=Last("1 USD/3"); Assert.Equal("0.33 USD",thirds.Display);
        Assert.Equal(new Rational(1,3),thirds.Value!.Value.Money.Magnitude.Scalar);
        Assert.Equal("1 USD",Last("third=1 USD/3\nthird*3").Display);
        Assert.Equal("2.68 USD",Last("2.675 USD").Display);
        Assert.Equal("-2.68 USD",Last("-2.675 USD").Display);
        Assert.Equal("1235 JPY",Last("1234.5 JPY").Display);
        Assert.Equal("1.235 KWD",Last("1.2345 KWD").Display);
        Assert.Equal("12.3456 USD",Last("12.34564 USD to 4 decimals").Display);
        Assert.Equal("0.01235 USD",Last("0.012345 USD to 4 sig figs").Display);
        Assert.Equal("12.35 USD",Last("12.37 USD to nearest 0.05 USD").Display);
    }
    [Fact]
    public void IdentityCurrencyAndSameCurrencyArithmeticNeedNoDownloadedData()
    {
        var session=new SheetEvaluationSession();
        var result=session.EvaluateWithFunctions("f(x)=x in USD\n100 USD+20 USD\nf(10 USD)\n3",FunctionLibrary.Empty,[]);
        Assert.False(result.UsesCurrencyRates); Assert.True(result.HasMoney); Assert.False(result.UsesCurrentDate);
        Assert.Empty(result.CurrencyRequests); Assert.Equal("120 USD",result.Results[1].Display); Assert.Equal("10 USD",result.Results[2].Display);
    }
    [Fact]
    public void MissingAndChangedRatesInvalidateTheirReadersWithoutReparsingStaticMoney()
    {
        var session=new SheetEvaluationSession(); const string source="price=100 EUR\nprice in USD\n4";
        var missing=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[]);
        Assert.NotNull(missing.Results[1].Error); Assert.True(missing.UsesCurrencyRates); Assert.Contains(missing.CurrencyRequests,request=>request.Date is null);
        Assert.Equal("200 USD",session.Evaluate(source,context:Context())[1].Display);
        Assert.Equal(0,session.LastStatistics.ParsedLines); Assert.Equal(2,session.LastStatistics.ReusedResults);
        Assert.Equal("300 USD",session.Evaluate(source,context:Context(3))[1].Display);
        Assert.Equal(2,session.LastStatistics.ReusedResults);
        var reused=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:Context(3));
        Assert.True(reused.UsesCurrencyRates); Assert.Single(reused.CurrencyRequests); Assert.Equal(3,session.LastStatistics.ReusedResults);
    }
    [Fact]
    public void HistoricalScopeAppliesToMixedArithmeticAndNestedSavedFunctions()
    {
        var result=Last("g(x)=x USD+1 EUR\nf(x)=g(x)\nf(2) in USD on 2024-01-01");
        Assert.Null(result.Error); Assert.Equal("3.11 USD",result.Display);
        Assert.Contains(result.Explanation,step=>step.Assumption?.Contains("2023-12-29")==true && step.Assumption.Contains("2024-01-01"));
        Assert.NotNull(Last("converted=1 EUR in USD\nconverted in EUR on 2024-01-01").Error);
        Assert.NotNull(Last("converted=1 EUR in USD\nconverted in USD on 2024-01-01").Error);
    }
    [Fact]
    public void AggregatesFunctionsAndRatesRemainTyped()
    {
        Assert.Equal("120 USD",Last("100 USD\n10 EUR\nsum").Display);
        Assert.Equal("60 USD",Last("100 USD\n10 EUR\naverage").Display);
        Assert.Equal("50%",Last("share(1 EUR,4 USD)").Display);
        Assert.Equal("100%",Last("change(1 EUR,4 USD)").Display);
        Assert.Equal("1 USD",Last("abs(-1 USD)").Display);
        Assert.NotNull(Last("1 USD\n2\nsum").Error);
        Assert.Throws<ArithmeticException>(()=>Last("1 USD").Value!.Value.Number);
    }
    [Fact]
    public void PinnedCodesAreWiredWithoutClaimingRateAvailability()
    {
        Assert.Equal(245,CurrencyCatalog.Definitions.Count);
        foreach(var currency in CurrencyCatalog.Definitions)
        {
            var value=Last("1 "+currency.Code);
            Assert.Null(value.Error); Assert.Equal(currency.Code,value.Value!.Value.Money.Currency);
            foreach(var alias in currency.Aliases)
            { var aliased=Last("1 "+alias); Assert.Null(aliased.Error); Assert.Equal(currency.Code,aliased.Value!.Value.Money.Currency); }
        }
        Assert.NotNull(Last("1 BTC in USD").Error);
        Assert.NotNull(Last("1 RUB in USD").Error);
        Assert.NotNull(Last("1 XAU in USD").Error);
        Assert.NotNull(Last("100¥").Error);
        Assert.Equal("2",Last("USD=1\nUSD+1").Display);
    }
    [Fact]
    public void RateReciprocityAndRoundTripsUseIndependentIntegerRatios()
    {
        var random=new Random(73128);
        for(var trial=0;trial<500;trial++)
        {
            var euro=random.Next(1,10000); var dollar=random.Next(1,10000); var amount=random.Next(-10000,10000);
            var snapshot=new CurrencyRateSnapshot("synthetic oracle","EUR",new(2026,10,30),DateTimeOffset.UnixEpoch,
                new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(dollar,euro)});
            var context=Context() with {CurrencyRates=new(snapshot,[])};
            var converted=Last($"{amount} EUR in USD",context).Value!.Value.Money;
            Assert.Equal(new Rational((long)amount*dollar,euro),converted.Magnitude.Scalar);
            Assert.Equal(new Rational(amount,1),Last($"x={amount} EUR in USD\nx in EUR",context).Value!.Value.Money.Magnitude.Scalar);
        }
    }
    [Theory]
    [InlineData("1 USD + 2")]
    [InlineData("sqrt(1 USD)")]
    [InlineData("1 USD*2 EUR")]
    [InlineData("1 USD^2")]
    [InlineData("1 USD!")]
    [InlineData("1% USD")]
    [InlineData("1 USD in EUR on 3000-01-01")]
    [InlineData("1 USD in USD on 3000-01-01")]
    [InlineData("1 USD in EUR on 1")]
    [InlineData("1 USD in XYZ")]
    public void InvalidMoneyAndUnavailableCoverageFailExplicitly(string source) => Assert.NotNull(Last(source).Error);
    [Fact]
    public void TooManyHistoricalDatesFailWithoutCommittingAPartialSheetCache()
    {
        var session=new SheetEvaluationSession(); session.Evaluate("7",context:Context());
        var source=string.Join('\n',Enumerable.Range(0,65).Select(index=>$"1 EUR in USD on {new DateOnly(2024,1,1).AddDays(index):yyyy-MM-dd}"));
        Assert.Throws<ArgumentException>(()=>session.Evaluate(source,context:Context()));
        Assert.Equal("7",session.Evaluate("7",context:Context())[0].Display); Assert.Equal(1,session.LastStatistics.ReusedResults);
    }
}
