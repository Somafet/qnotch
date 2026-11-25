using System.Globalization;
using System.Net;
using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Providers;

public sealed class CurrencyRateHttpException(HttpStatusCode status,TimeSpan? retryAfter = null) : IOException("Currency provider returned HTTP " + (int)status)
{
    public HttpStatusCode Status { get; } = status;
    public TimeSpan? RetryAfter { get; } = retryAfter;
}

/// <summary>One explicit, bounded ECB request. No clock reads, credentials, retries, sheet text or amount input.</summary>
public sealed class EcbRateClient(HttpClient client)
{
    public const string Provider = "ECB via Frankfurter";
    public const string Source = "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html";
    public const string Terms = "https://www.ecb.europa.eu/services/using-our-site/disclaimer/html/index.en.html";
    public const int MaxResponseBytes = 262144;
    public static readonly DateOnly FirstDate = new(1999,1,4);
    public static Uri RequestUri(DateOnly? date) => new("https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR" +
        (date is { } value ? "&date=" + value.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture) : ""));
    public async Task<CurrencyRateSnapshot> FetchAsync(DateOnly? date,DateTimeOffset now,CancellationToken cancellationToken = default)
    {
        var today = DateOnly.FromDateTime(now.DateTime);
        if (date is { } requested && (requested < FirstDate || requested > today)) throw new InvalidDataException("ECB historical date is outside available bounds");
        return Parse(await Download(client,RequestUri(date),now,cancellationToken).ConfigureAwait(false),date,now);
    }
    /// <summary>Shared bounded GET for the fixed Frankfurter provider routes; never follows redirects or sends a body.</summary>
    internal static async Task<byte[]> Download(HttpClient client,Uri uri,DateTimeOffset now,CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        using var request = new HttpRequestMessage(HttpMethod.Get,uri);
        request.Headers.Accept.ParseAdd("application/json");
        using var response = await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,timeout.Token).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            var retry = response.Headers.RetryAfter?.Delta ?? (response.Headers.RetryAfter?.Date is { } when ? when-now : (TimeSpan?)null);
            if (retry is { } duration) retry = duration < TimeSpan.Zero ? TimeSpan.Zero : duration > TimeSpan.FromDays(1) ? TimeSpan.FromDays(1) : duration;
            throw new CurrencyRateHttpException(response.StatusCode,retry);
        }
        if (response.RequestMessage?.RequestUri != request.RequestUri) throw new InvalidDataException("Unexpected currency provider redirect");
        if (response.Content.Headers.ContentLength is > MaxResponseBytes) throw new InvalidDataException("Currency response exceeds size limit");
        await using var body = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
        using var buffer = new MemoryStream(); var chunk = new byte[8192];
        while (true)
        {
            var count = await body.ReadAsync(chunk,timeout.Token).ConfigureAwait(false); if (count == 0) break;
            if (buffer.Length + count > MaxResponseBytes) throw new InvalidDataException("Currency response exceeds size limit");
            buffer.Write(chunk,0,count);
        }
        return buffer.ToArray();
    }
    public static CurrencyRateSnapshot Parse(ReadOnlyMemory<byte> bytes,DateOnly? requested,DateTimeOffset retrievedAt) =>
        Parse(bytes,requested,retrievedAt,Provider,FirstDate,10);
    /// <summary>Parses EUR-based Frankfurter v2 rows of one provider and one publication date.</summary>
    internal static CurrencyRateSnapshot Parse(ReadOnlyMemory<byte> bytes,DateOnly? requested,DateTimeOffset retrievedAt,string provider,DateOnly firstDate,int maximumAgeDays)
    {
        if (bytes.Length > MaxResponseBytes) throw new InvalidDataException("Currency response exceeds size limit");
        try
        {
            using var json = JsonDocument.Parse(bytes,new JsonDocumentOptions{MaxDepth=8});
            if (json.RootElement.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Expected ECB rate rows");
            var rates = new Dictionary<string,Rational>(StringComparer.Ordinal); DateOnly? date = null;
            foreach (var row in json.RootElement.EnumerateArray())
            {
                if (rates.Count >= CurrencyRateSnapshot.MaxCurrencies || row.ValueKind != JsonValueKind.Object ||
                    row.EnumerateObject().Select(property=>property.Name).Distinct(StringComparer.Ordinal).Count() != row.EnumerateObject().Count()) throw new InvalidDataException("Invalid ECB row set");
                var actual = DateOnly.ParseExact(row.GetProperty("date").GetString()!,"yyyy-MM-dd",CultureInfo.InvariantCulture);
                var code = row.GetProperty("quote").GetString()!;
                if (row.GetProperty("base").GetString() != "EUR" || !CurrencyCatalog.ValidCode(code) || !CurrencyCatalog.TryCode(code,out _) ||
                    date is { } previous && previous != actual || row.GetProperty("rate").ValueKind != JsonValueKind.Number || !rates.TryAdd(code,Decimal(row.GetProperty("rate").GetRawText())))
                    throw new InvalidDataException("Invalid ECB currency identity/date/rate");
                date = actual;
            }
            var endpoint = requested ?? DateOnly.FromDateTime(retrievedAt.DateTime);
            if (date is null || date < firstDate || date > endpoint || endpoint.DayNumber - date.Value.DayNumber > maximumAgeDays) throw new InvalidDataException("Rate publication date is unavailable or inconsistent");
            return new(provider,"EUR",date.Value,retrievedAt,rates);
        }
        catch (Exception error) when (error is JsonException or FormatException or ArithmeticException or InvalidOperationException or KeyNotFoundException or ArgumentException)
        { throw new InvalidDataException("Invalid rate response",error); }
    }
    private static Rational Decimal(string text)
    {
        if (text.Length > 128) throw new InvalidDataException("Currency rate precision limit exceeded");
        var parts = text.Split(['e','E']);
        if (parts.Length > 2) throw new InvalidDataException("Invalid currency decimal");
        var mantissa = Rational.Parse(parts[0]);
        if (parts.Length == 1) return mantissa;
        if (!int.TryParse(parts[1],NumberStyles.AllowLeadingSign,CultureInfo.InvariantCulture,out var exponent) || Math.Abs((long)exponent) > 40) throw new InvalidDataException("Currency exponent limit exceeded");
        var scale = new Rational(BigInteger.Pow(10,Math.Abs(exponent)),1);
        return exponent < 0 ? mantissa/scale : mantissa*scale;
    }
}
