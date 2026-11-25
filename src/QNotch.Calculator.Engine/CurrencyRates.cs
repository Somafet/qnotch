using System.Collections.ObjectModel;
using System.Security.Cryptography;
using System.Text;

namespace Calc.Core;

public sealed class CurrencyRateSnapshot
{
    public const int MaxCurrencies = 256;
    /// <summary>Provider identity of the European Commission's monthly InforEuro accounting rates.</summary>
    public const string MonthlyEuProvider = "EC InforEuro via Frankfurter";
    public bool IsMonthly => Provider == MonthlyEuProvider;
    public string Provider { get; }
    public string BaseCurrency { get; }
    public DateOnly AsOf { get; }
    public DateTimeOffset RetrievedAt { get; }
    public IReadOnlyDictionary<string,Rational> Rates { get; }
    public string Key { get; }
    public CurrencyRateSnapshot(string provider, string baseCurrency, DateOnly asOf, DateTimeOffset retrievedAt, IEnumerable<KeyValuePair<string,Rational>> rates)
    {
        if (provider.Length is < 1 or > 80 || !CurrencyCatalog.ValidCode(baseCurrency)) throw new ArithmeticException("Invalid currency snapshot identity");
        Provider = provider; BaseCurrency = baseCurrency; AsOf = asOf; RetrievedAt = retrievedAt.ToUniversalTime();
        var copies = new Dictionary<string,Rational>(StringComparer.Ordinal);
        foreach (var pair in rates)
        {
            if (copies.Count >= MaxCurrencies || !CurrencyCatalog.ValidCode(pair.Key) || pair.Value.Numerator <= 0 || pair.Value.Numerator.GetBitLength() > 256 || pair.Value.Denominator.GetBitLength() > 256 || !copies.TryAdd(pair.Key,pair.Value))
                throw new ArithmeticException("Invalid or oversized currency rate snapshot");
        }
        if (!copies.TryGetValue(baseCurrency,out var identity) || identity != new Rational(1,1)) throw new ArithmeticException("Currency base rate must be one");
        Rates = new ReadOnlyDictionary<string,Rational>(copies);
        Key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(provider + ":" + baseCurrency + ":" + asOf.ToString("yyyy-MM-dd",System.Globalization.CultureInfo.InvariantCulture) + ":" +
            string.Join(';',copies.OrderBy(pair => pair.Key,StringComparer.Ordinal).Select(pair => pair.Key + "=" + pair.Value)))));
    }
    internal Rational CrossRate(string from,string to)
    {
        if (!Rates.TryGetValue(from,out var a) || !Rates.TryGetValue(to,out var b)) throw new ArithmeticException($"Currency rate unavailable: {from} to {to}");
        return b/a;
    }
}

public sealed class CurrencyRateBook
{
    public const int MaxHistoricalSnapshots = 64;
    public static CurrencyRateBook Empty { get; } = new(null,[]);
    public CurrencyRateSnapshot? Latest { get; }
    public IReadOnlyDictionary<DateOnly,CurrencyRateSnapshot> Historical { get; }
    public string Key { get; }
    public CurrencyRateBook(CurrencyRateSnapshot? latest, IEnumerable<KeyValuePair<DateOnly,CurrencyRateSnapshot>> historical)
    {
        Latest = latest; var copies = new Dictionary<DateOnly,CurrencyRateSnapshot>();
        foreach (var pair in historical)
        {
            if (copies.Count >= MaxHistoricalSnapshots || pair.Value is null || pair.Value.AsOf > pair.Key || pair.Key.DayNumber - pair.Value.AsOf.DayNumber > 10 || !copies.TryAdd(pair.Key,pair.Value))
                throw new ArithmeticException("Invalid historical currency snapshot");
        }
        Historical = new ReadOnlyDictionary<DateOnly,CurrencyRateSnapshot>(copies);
        Key = (Latest?.Key ?? "none") + ":" + Latest?.RetrievedAt.ToString("O") + ":" +
            string.Join(';',copies.OrderBy(pair => pair.Key).Select(pair => pair.Key.DayNumber + "=" + pair.Value.Key + ":" + pair.Value.RetrievedAt.ToString("O")));
    }
    internal CurrencyRateSnapshot Require(DateOnly? requested) => requested is null ? Latest ?? throw new ArithmeticException("Daily currency rates unavailable; download rates explicitly") :
        Historical.TryGetValue(requested.Value,out var value) ? value : throw new ArithmeticException($"Historical currency rates unavailable for {requested:yyyy-MM-dd}");
}

public sealed record CurrencyRateRequest(DateOnly? Date);
