using Calc.Core;
using Calc.Providers;

namespace Calc.Providers.Tests;

public sealed class OfflineTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 31, 12, 0, 0, TimeSpan.Zero);
    private static SheetEvaluation Evaluate(string source) => new SheetEvaluationSession().EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: new(new DateOnly(2026, 10, 31)));
    private static DateTimeOffset? Due(bool enabled, SheetEvaluation evaluated) => CurrencyRefreshPolicy.Next(enabled, true, false,
        evaluated.UsesCurrencyRates && evaluated.CurrencyRequests.Any(request => request.Date is null), false, null, Now, null);

    [Fact]
    public void AutomaticDownloadNeedsExplicitConsentEvenWithLatestRateDemand()
    {
        var demand = Evaluate("100 USD in EUR");
        Assert.True(demand.UsesCurrencyRates);
        Assert.Null(Due(false, demand));
        Assert.Equal(Now, Due(true, demand));
    }
    [Theory]
    [InlineData("")]
    [InlineData("price = 120\ndiscount = 15%\nprice * (1 - discount)")]
    [InlineData("10 km in m\n2026-10-31 + 30 days\nsolve x^2 = 4\n192.0.2.0/24")]
    [InlineData("rate(x) = x * 2\nrate(4)")]
    public void NoProviderRunsForASheetWithoutCurrencyDemand(string source)
    {
        var evaluated = Evaluate(source);
        Assert.False(evaluated.UsesCurrencyRates); Assert.Empty(evaluated.CurrencyRequests);
        Assert.Null(Due(true, evaluated)); // Even an enabled preference has nothing to do.
    }
    [Fact]
    public void ConversionWithoutCachedRatesIsExplicitlyUnavailableAndOtherLinesCalculate()
    {
        var results = Evaluate("1 + 1\n100 USD in EUR\n2 * 3").Results;
        Assert.Equal("2", results[0].Display); Assert.Equal("6", results[2].Display);
        Assert.Null(results[1].Value);
        Assert.Contains("unavailable", results[1].Error, StringComparison.Ordinal);
        Assert.DoesNotContain("0", results[1].Display, StringComparison.Ordinal);
    }
    [Fact]
    public void HistoricalConversionWithoutCachedRatesNamesTheMissingDate()
    {
        var result = Evaluate("100 USD in EUR on 2023-12-29").Results[0];
        Assert.Null(result.Value);
        Assert.Contains("unavailable", result.Error, StringComparison.Ordinal);
    }
    [Fact]
    public void ARequestCarriesOnlyTheFixedBaseAndAnOptionalDate()
    {
        Assert.Equal("https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR", EcbRateClient.RequestUri(null).AbsoluteUri);
        Assert.Equal("https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR&date=2023-12-29", EcbRateClient.RequestUri(new(2023, 12, 29)).AbsoluteUri);
    }
}
