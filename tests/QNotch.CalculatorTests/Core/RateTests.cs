using Calc.Core;
using System.Text.Json;
using System.Numerics;

namespace Calc.Core.Tests;

public sealed class RateTests
{
    private static LineResult Last(string source)
    {var row=SheetEvaluator.Evaluate(source)[^1];Assert.Null(row.Error);Assert.NotNull(row.Value);return row;}
    public static IEnumerable<object[]> OracleCases()
    {
        using var stream=typeof(RateTests).Assembly.GetManifestResourceStream("Calc.RateOracle")!;using var doc=JsonDocument.Parse(stream);
        return doc.RootElement.GetProperty("cases").EnumerateArray().Select(row=>new object[]{row.GetRawText()}).ToArray();
    }
    [Theory,MemberData(nameof(OracleCases))]
    public void IndependentExactRateOracle(string json)
    {
        using var doc=JsonDocument.Parse(json);var row=doc.RootElement;var value=Last(row.GetProperty("source").GetString()!).Value!.Value;
        static Rational Read(JsonElement pair)=>new(BigInteger.Parse(pair[0].GetString()!),BigInteger.Parse(pair[1].GetString()!));
        var expected=Read(row.GetProperty("exact"));
        if(row.GetProperty("kind").GetString()=="uptime")
        {Assert.Equal(expected,value.UptimeBudget.DowntimeSeconds);Assert.Equal(Read(row.GetProperty("interval")),value.UptimeBudget.IntervalSeconds);}
        else if(row.GetProperty("kind").GetString()=="cost")Assert.Equal(expected,value.Money.Magnitude.Exact.Rational);
        else Assert.Equal(expected,value.Exact.Rational);
    }
    [Theory]
    [InlineData("5 GB at 100 Mbps","6 min 40 s")]
    [InlineData("transfer(5 GB,100 Mbit/s)","6 min 40 s")]
    [InlineData("1 TB / 3 h in MB/s","92.59 MB/s")]
    [InlineData("throughput(1 TB,3 h)","92.59 MB/s")]
    [InlineData("99.9% uptime","43 min 50 s")]
    [InlineData("99.9% uptime for 30 days","43 min 12 s")]
    [InlineData("downtime(99.9%,30 days)","43 min 12 s")]
    [InlineData("1.2M tokens at $3/M","3.6 USD")]
    [InlineData("100 req/s at $0.20/M for 30 days","51.84 USD")]
    [InlineData("$0.0832/h for 30 days","59.9 USD")]
    [InlineData("100 Mbps for 1 h","360000 Mbit")]
    [InlineData("n=1.2M tokens\np=$3/M\nn at p","3.6 USD")]
    [InlineData("1000 at 10% for 1 year","1100")]
    [InlineData("2027-01-02 at 12:00","2027-01-02T12:00:00")]
    public void PublicExamplesAndExistingAtMeanings(string source,string expected)=>Assert.Equal(expected,Last(source).Display);
    [Fact]
    public void ExactStoredValuesAndTypedCopies()
    {
        var throughput=Last("1 TB / 3 h in MB/s").Value!.Value;Assert.Equal(new Rational(20_000_000_000L,27),throughput.Exact.Rational);
        var uptime=Last("99.9% uptime").Value!.Value;Assert.Equal(new Rational(13149,5),uptime.UptimeBudget.DowntimeSeconds);
        foreach(var source in new[]{"100 req/s","1.2M tokens","$0.00001/M tokens","99.9% uptime","99.9% uptime for 30 days"})
        {var value=Last(source).Value!.Value;Assert.Equal(value,Last(value.CopyText).Value!.Value);}
    }
    [Theory]
    [InlineData("5 GB at 0 Mbps")][InlineData("5 GB at -100 Mbps")][InlineData("transfer(-1 GB,1 Mbps)")]
    [InlineData("throughput(1 GB,0 s)")][InlineData("downtime(101%,1 day)")][InlineData("downtime(99.9%,0 s)")]
    [InlineData("uptime(99.9)")][InlineData("1 tokens+1 requests")][InlineData("1 requests at tokenPrice(3 USD,1000000)")]
    [InlineData("tokenPrice(3 USD,0)")][InlineData("tokenPrice(-3 USD,100)")][InlineData("$1/month for 30 days")]
    [InlineData("100 req/s at $1/M for 1 month")][InlineData("$1/h for -1 s")]
    public void DomainsAndDimensionsFail(string source)=>Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);
    [Theory]
    [InlineData("100 req/s in requests/h","360000 requests/h")]
    [InlineData("100 req/s for 1 h","360000 requests")]
    [InlineData("$6/M / 2","3 USD/M")]
    [InlineData("2 * ($3/M)","6 USD/M")]
    [InlineData("$3/M + $2/M","5 USD/M")]
    [InlineData("$6 / tokenPrice(3 USD,1000000)","2000000 tokens")]
    [InlineData("100 tokens + 10%","110 tokens")]
    [InlineData("100 tokens / 25 tokens","4")]
    [InlineData("1 tokens\n3 tokens\naverage","2 tokens")]
    [InlineData("$2/M\n$4/M\naverage","3 USD/M")]
    [InlineData("(123.45 tokens) to 1 decimal","123.5 tokens")]
    [InlineData("(99.9% uptime) in s","2629.8 s")]
    [InlineData("tokens=7\ntokens+1","8")]
    [InlineData("M=2\n6 USD/M","3 USD")]
    [InlineData("1 MBps in Mbit/s","8 Mbit/s")]
    [InlineData("1 MiBps in Mbit/s","8.388608 Mbit/s")]
    [InlineData("2027-01-02 at (12:00) GB in UTC","2027-01-02T12:00:00Z")]
    public void RatesComposeAndExistingNamesKeepPriority(string source,string expected)=>Assert.Equal(expected,Last(source).Display);
    [Fact]
    public void ConvertedUsageAggregatesRemainExcludedFromLaterTotals()
    {
        var rows=SheetEvaluator.Evaluate("100 req/s\n200 req/s\nsum in requests/h\nsum in requests/h");
        Assert.All(rows,row=>Assert.Null(row.Error));Assert.Equal("1080000 requests/h",rows[2].Display);Assert.Equal(rows[2].Display,rows[3].Display);
    }
    [Fact]
    public void RatesSurviveSavedFunctionsAndCaseSensitiveFingerprinting()
    {
        var slow=new FunctionLibrary([new("wire",[],"1 Mbps")]);var fast=new FunctionLibrary([new("wire",[],"1 MBps")]);
        Assert.NotEqual(slow.Fingerprint,fast.Fingerprint);Assert.Equal(3,slow.MinimumCatalogVersion);
        var engine=new SheetEvaluationSession();var a=engine.EvaluateWithFunctions("wire()",slow,[]).Results[0].Value!.Value;
        var b=engine.EvaluateWithFunctions("wire()",fast,[]).Results[0].Value!.Value;Assert.Equal(a.Exact.Rational*new Rational(8,1),b.Exact.Rational);
        Assert.Throws<FormatException>(()=>new FunctionLibrary([new("transfer",[],"1")]));
        Assert.Throws<FormatException>(()=>new FunctionLibrary([new("bad",[],"usageCost(1)")]));
    }
    [Fact]
    public void CurrencyPricesUseExplicitSnapshotsAndKeepProvenance()
    {
        var snapshot=new CurrencyRateSnapshot("Test daily rates","EUR",new(2026,10,30),new(2026,10,30,17,0,0,TimeSpan.Zero),new Dictionary<string,Rational>{{"EUR",new(1,1)},{"USD",new(2,1)}});
        var context=new EvaluationContext(CurrencyRates:new(snapshot,[]));
        var row=SheetEvaluator.Evaluate("p=tokenPrice(3 EUR,1000000) in USD\n1.2M tokens at p",context:context)[^1];
        Assert.Null(row.Error);Assert.Equal("7.2 USD",row.Display);Assert.NotNull(row.Value!.Value.Money.RateStamp);
        var missing=SheetEvaluator.Evaluate("tokenPrice(3 EUR,1000000) in USD")[0];Assert.NotNull(missing.Error);
    }
    [Fact]
    public void TracesRetainExactRatesAndAssumptionsAndRespectCancellation()
    {
        var row=Last("1 TB / 3 h in MB/s");Assert.Contains(row.Explanation,s=>s.Assumption?.Contains("20000000000/27",StringComparison.Ordinal)==true);
        var uptime=Last("99.9% uptime");Assert.Contains(uptime.Explanation,s=>s.Assumption?.Contains("a mean-month convention",StringComparison.Ordinal)==true);
        using var cancelled=new CancellationTokenSource();cancelled.Cancel();Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("5 GB at 100 Mbps",cancellationToken:cancelled.Token));
    }
}

