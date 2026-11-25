using System.Net;
using System.Text;
using Calc.Core;
using Calc.Providers;

namespace Calc.Providers.Tests;

public class EcbRateTests
{
    private static readonly DateTimeOffset Now = new(2026,10,31,12,0,0,TimeSpan.Zero);
    private const string Valid = "[{\"date\":\"2026-10-30\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1},{\"date\":\"2026-10-30\",\"base\":\"EUR\",\"quote\":\"USD\",\"rate\":1.105}]";
    private sealed class Handler(Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> response) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
        { var result=await response(request,token); result.RequestMessage ??= request; return result; }
    }
    [Fact]
    public void RecordedHolidayRequestMatchesTheOfficialPublishedEcbDateAndRates()
    {
        using var stream=typeof(EcbRateTests).Assembly.GetManifestResourceStream("Calc.EcbRecorded")!;
        using var bytes=new MemoryStream(); stream.CopyTo(bytes);
        var snapshot=EcbRateClient.Parse(bytes.ToArray(),new(2024,1,1),Now);
        Assert.Equal(new DateOnly(2023,12,29),snapshot.AsOf); Assert.Equal(31,snapshot.Rates.Count);
        Assert.Equal(Rational.Parse("1.1050"),snapshot.Rates["USD"]); Assert.Equal(Rational.Parse("156.33"),snapshot.Rates["JPY"]);
        Assert.Equal(Rational.Parse("0.86905"),snapshot.Rates["GBP"]);
        Assert.Throws<NotSupportedException>(()=>((IDictionary<string,Rational>)snapshot.Rates).Add("XYZ",new(1,1)));
    }
    [Fact]
    public async Task RequestsContainOnlyTheFixedBaseAndOptionalDate()
    {
        Uri? seen=null;
        using var client=new HttpClient(new Handler((request,_)=>{seen=request.RequestUri; Assert.Null(request.Content); Assert.Empty(request.Headers.Authorization?.ToString()??""); return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(Valid)});}));
        var result=await new EcbRateClient(client).FetchAsync(null,Now);
        Assert.Equal("https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR",seen!.AbsoluteUri);
        Assert.Equal(EcbRateClient.Provider,result.Provider);
        Assert.Equal("https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR&date=2024-01-01",EcbRateClient.RequestUri(new(2024,1,1)).AbsoluteUri);
    }
    [Theory]
    [InlineData("[]")]
    [InlineData("{}")]
    [InlineData("<html>unavailable</html>")]
    [InlineData("[{\"date\":\"2026-10-30\",\"base\":\"USD\",\"quote\":\"USD\",\"rate\":1}]")]
    [InlineData("[{\"date\":\"2026-10-30\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":0}]")]
    [InlineData("[{\"date\":\"2026-10-30\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":2}]")]
    [InlineData("[{\"date\":\"2026-10-30\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1,\"rate\":2}]")]
    [InlineData("[{\"date\":\"2026-11-01\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]")]
    [InlineData("[{\"date\":\"2026-01-01\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]")]
    [InlineData("[{\"date\":null,\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]")]
    public void InvalidResponsesNeverBecomeRates(string value) => Assert.Throws<InvalidDataException>(()=>EcbRateClient.Parse(Encoding.UTF8.GetBytes(value),null,Now));
    [Fact]
    public void DuplicateMixedDateAndScientificDecimalCasesAreExactAndBounded()
    {
        var scientific=Valid.Replace("1.105}","1.105e0}");
        Assert.Equal(Rational.Parse("1.105"),EcbRateClient.Parse(Encoding.UTF8.GetBytes(scientific),null,Now).Rates["USD"]);
        Assert.Throws<InvalidDataException>(()=>EcbRateClient.Parse(Encoding.UTF8.GetBytes(Valid.Replace("1.105}","1e999}")),null,Now));
        Assert.Throws<InvalidDataException>(()=>EcbRateClient.Parse(Encoding.UTF8.GetBytes(Valid.Replace("\"quote\":\"USD\"","\"quote\":\"EUR\"")),null,Now));
        Assert.Throws<InvalidDataException>(()=>EcbRateClient.Parse(Encoding.UTF8.GetBytes(Valid.Replace("\"quote\":\"USD\"","\"quote\":\"XYZ\"")),null,Now));
        Assert.Throws<InvalidDataException>(()=>EcbRateClient.Parse(Encoding.UTF8.GetBytes(Valid.Replace("\"quote\":\"USD\"","\"date\":\"2026-10-29\",\"quote\":\"USD\"")),null,Now));
    }
    [Theory]
    [InlineData(429)] [InlineData(500)] [InlineData(404)]
    public async Task HttpFailuresRetainStatusAndBoundRetryAdvice(int status)
    {
        using var client=new HttpClient(new Handler((_,_)=>{var response=new HttpResponseMessage((HttpStatusCode)status);response.Headers.RetryAfter=new(TimeSpan.FromDays(10));return Task.FromResult(response);}));
        var error=await Assert.ThrowsAsync<CurrencyRateHttpException>(()=>new EcbRateClient(client).FetchAsync(null,Now));
        Assert.Equal((HttpStatusCode)status,error.Status); Assert.Equal(TimeSpan.FromDays(1),error.RetryAfter);
    }
    private sealed class NonSeekable(byte[] bytes) : MemoryStream(bytes)
    { public override bool CanSeek=>false; }
    [Fact]
    public async Task BothDeclaredAndStreamingOversizedBodiesAreRejected()
    {
        foreach(var streaming in new[]{false,true})
        {
            using var client=new HttpClient(new Handler((_,_)=>Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
                {Content=streaming?new StreamContent(new NonSeekable(new byte[EcbRateClient.MaxResponseBytes+1])):new ByteArrayContent(new byte[EcbRateClient.MaxResponseBytes+1])})));
            await Assert.ThrowsAsync<InvalidDataException>(()=>new EcbRateClient(client).FetchAsync(null,Now));
        }
    }
    [Fact]
    public async Task CancellationFutureDatesAndRedirectsCannotYieldSuccessfulSnapshots()
    {
        using var canceled=new CancellationTokenSource(); canceled.Cancel();
        using var client=new HttpClient(new Handler((_,token)=>{token.ThrowIfCancellationRequested();return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(Valid)});}));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(()=>new EcbRateClient(client).FetchAsync(null,Now,canceled.Token));
        await Assert.ThrowsAsync<InvalidDataException>(()=>new EcbRateClient(client).FetchAsync(new(3000,1,1),Now));
        using var redirect=new HttpClient(new Handler((_,_)=>Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){RequestMessage=new(HttpMethod.Get,"https://example.invalid/"),Content=new StringContent(Valid)})));
        await Assert.ThrowsAsync<InvalidDataException>(()=>new EcbRateClient(redirect).FetchAsync(null,Now));
    }
}
