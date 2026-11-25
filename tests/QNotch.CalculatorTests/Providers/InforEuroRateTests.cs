using System.Net;
using System.Text;
using System.Text.Json;
using Calc.Core;
using Calc.Providers;

namespace Calc.Providers.Tests;

public class InforEuroRateTests
{
    private static readonly DateTimeOffset Now = new(2026,11,1,12,0,0,TimeSpan.Zero);
    private sealed class Handler(Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> response) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
        { var result=await response(request,token); result.RequestMessage ??= request; return result; }
    }
    private static byte[] Resource(string name)
    {
        using var stream=typeof(InforEuroRateTests).Assembly.GetManifestResourceStream(name)!;
        using var bytes=new MemoryStream(); stream.CopyTo(bytes); return bytes.ToArray();
    }
    [Fact]
    public void RecordedResponseMatchesTheOfficialCommissionPublicationForEveryCode()
    {
        var snapshot=InforEuroRateClient.Parse(Resource("Calc.InforEuroRecorded"),null,Now);
        Assert.Equal(new DateOnly(2026,10,1),snapshot.AsOf); Assert.True(snapshot.IsMonthly);
        Assert.Equal(152,snapshot.Rates.Count); Assert.Equal(new Rational(1,1),snapshot.Rates["EUR"]);
        // Independent oracle: the Commission's own InforEuro API for October 2026, retrieved separately.
        using var official=JsonDocument.Parse(Resource("Calc.InforEuroOfficial"));
        var rates=official.RootElement.GetProperty("rates").EnumerateObject().ToDictionary(p=>p.Name=="ZIG"?"ZWG":p.Name,p=>Rational.Parse(p.Value.GetString()!));
        Assert.Equal(rates.Keys.OrderBy(k=>k,StringComparer.Ordinal),snapshot.Rates.Keys.OrderBy(k=>k,StringComparer.Ordinal));
        foreach(var (code,value) in rates) Assert.Equal(value,snapshot.Rates[code]);
        Assert.All(snapshot.Rates.Keys,code=>Assert.True(CurrencyCatalog.TryCode(code,out _)));
        Assert.True(snapshot.Rates.Count>EcbRateClient.Parse(Resource("Calc.EcbRecorded"),new(2024,1,1),Now).Rates.Count*4);
    }
    [Fact]
    public async Task RequestsNameOnlyTheFixedProviderBaseAndOptionalDate()
    {
        Uri? seen=null; var body=Encoding.UTF8.GetString(Resource("Calc.InforEuroRecorded"));
        using var client=new HttpClient(new Handler((request,_)=>{seen=request.RequestUri; Assert.Null(request.Content); Assert.Null(request.Headers.Authorization);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(body)});}));
        var result=await new InforEuroRateClient(client).FetchAsync(new(2026,10,17),Now);
        Assert.Equal("https://api.frankfurter.dev/v2/providers/INFOREURO/rates?base=EUR&date=2026-10-17",seen!.AbsoluteUri);
        Assert.Equal(InforEuroRateClient.Provider,result.Provider); Assert.Equal(new DateOnly(2026,10,1),result.AsOf);
        Assert.Equal("https://api.frankfurter.dev/v2/providers/INFOREURO/rates?base=EUR",InforEuroRateClient.RequestUri(null).AbsoluteUri);
        await Assert.ThrowsAsync<InvalidDataException>(()=>new InforEuroRateClient(client).FetchAsync(new(2026,11,2),Now));
        await Assert.ThrowsAsync<InvalidDataException>(()=>new InforEuroRateClient(client).FetchAsync(new(1990,1,1),Now));
    }
    [Theory]
    [InlineData("[{\"date\":\"2026-10-02\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]")]   // monthly rates are dated on the first
    [InlineData("[{\"date\":\"2026-08-01\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]")]   // older than the monthly bound
    [InlineData("[{\"date\":\"2026-12-01\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]")]   // future
    [InlineData("[{\"date\":\"2026-10-01\",\"base\":\"EUR\",\"quote\":\"USD\",\"rate\":1.1}]")] // base identity missing
    [InlineData("[]")]
    public void InvalidMonthlyResponsesNeverBecomeRates(string value)=>Assert.Throws<InvalidDataException>(()=>InforEuroRateClient.Parse(Encoding.UTF8.GetBytes(value),null,Now));
    [Fact]
    public void MonthlySnapshotsRoundTripThroughTheCacheAndDescribeTheirCadence()
    {
        var directory=Path.Combine(Path.GetTempPath(),"calc-inforeuro-"+Guid.NewGuid().ToString("N"));
        try
        {
            var snapshot=InforEuroRateClient.Parse(Resource("Calc.InforEuroRecorded"),null,Now);
            var cache=new CurrencyRateCache(directory); cache.Save(new(snapshot,new Dictionary<DateOnly,CurrencyRateSnapshot>()));
            var loaded=cache.Load().Book.Latest!;
            Assert.Equal(snapshot.Key,loaded.Key); Assert.True(loaded.IsMonthly);
            var context=new EvaluationContext(new(2026,11,1),CurrencyRates:new(loaded,[]));
            var result=SheetEvaluator.Evaluate("100 EUR in ZAR",context:context)[^1];
            Assert.Null(result.Error);
            var detail=string.Join(" ",result.Explanation.Select(step=>step.Assumption));
            Assert.Contains("monthly accounting rates",detail); Assert.DoesNotContain("STALE",detail);
            var stale=SheetEvaluator.Evaluate("100 EUR in ZAR",context:context with{Today=new(2026,11,30)})[^1];
            Assert.Contains("STALE",string.Join(" ",stale.Explanation.Select(step=>step.Assumption)));
        }
        finally { if(Directory.Exists(directory)) Directory.Delete(directory,true); }
    }
}
