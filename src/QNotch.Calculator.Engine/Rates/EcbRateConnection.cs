using System.Net;
using Calc.Core;

namespace Calc.Providers;

/// <summary>The only HTTP transport in Calc, created on the first explicit download or enabled daily refresh.
/// No cookies, redirects or credentials; failures reach the host as IOException, never as a rate.</summary>
public sealed class EcbRateConnection : IDisposable
{
    private readonly HttpClient client = new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate }) { Timeout = Timeout.InfiniteTimeSpan };
    public async Task<CurrencyRateSnapshot> FetchAsync(DateOnly? date, DateTimeOffset now, CancellationToken token = default)
    {
        try { return await new EcbRateClient(client).FetchAsync(date, now, token).ConfigureAwait(false); }
        catch (HttpRequestException error) { throw new IOException("Currency provider unreachable", error); }
    }
    public async Task<CurrencyRateSnapshot> FetchInforEuroAsync(DateOnly? date, DateTimeOffset now, CancellationToken token = default)
    {
        try { return await new InforEuroRateClient(client).FetchAsync(date, now, token).ConfigureAwait(false); }
        catch (HttpRequestException error) { throw new IOException("Currency provider unreachable", error); }
    }
    public void Dispose() => client.Dispose();
}
