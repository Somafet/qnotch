using System.Globalization;
using Calc.Core;

namespace Calc.Providers;

/// <summary>One explicit, bounded request for the European Commission's monthly InforEuro accounting rates
/// (one provider, not Frankfurter's blended feed). The URI carries only the provider, base EUR and an optional
/// date; no clock reads, credentials, retries, sheet text or amounts.</summary>
public sealed class InforEuroRateClient(HttpClient client)
{
    public const string Provider = CurrencyRateSnapshot.MonthlyEuProvider;
    public const string Source = "https://commission.europa.eu/funding-and-tenders/procedures-guidelines-tenders/information-contractors-and-beneficiaries/exchange-rate-inforeuro_en";
    public const string Terms = "https://commission.europa.eu/legal-notice_en";
    public const string Attribution = "Monthly accounting rates © European Union, CC BY 4.0; retrieved through Frankfurter and converted to exact cross rates by Calc";
    public static readonly DateOnly FirstDate = new(1994,3,1);
    /// <summary>A monthly rate is dated the first day of its month; a later requested day keeps that month's rate.</summary>
    public const int MaximumAgeDays = 62;
    public static Uri RequestUri(DateOnly? date) => new("https://api.frankfurter.dev/v2/providers/INFOREURO/rates?base=EUR" +
        (date is { } value ? "&date=" + value.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture) : ""));
    public async Task<CurrencyRateSnapshot> FetchAsync(DateOnly? date,DateTimeOffset now,CancellationToken cancellationToken = default)
    {
        var today = DateOnly.FromDateTime(now.DateTime);
        if (date is { } requested && (requested < FirstDate || requested > today)) throw new InvalidDataException("InforEuro date is outside available bounds");
        return Parse(await EcbRateClient.Download(client,RequestUri(date),now,cancellationToken).ConfigureAwait(false),date,now);
    }
    public static CurrencyRateSnapshot Parse(ReadOnlyMemory<byte> bytes,DateOnly? requested,DateTimeOffset retrievedAt)
    {
        var snapshot = EcbRateClient.Parse(bytes,requested,retrievedAt,Provider,FirstDate,MaximumAgeDays);
        if (snapshot.AsOf.Day != 1) throw new InvalidDataException("InforEuro rates must be dated the first day of their month");
        return snapshot;
    }
}
