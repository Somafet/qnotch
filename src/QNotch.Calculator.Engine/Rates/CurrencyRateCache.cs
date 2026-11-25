using System.Text.Json;
using Calc.Core;

namespace Calc.Providers;

public sealed record CurrencyCacheLoad(CurrencyRateBook Book,bool Recovered,string? Warning);

/// <summary>Bounded disposable-rate cache; never opens or writes sheet documents.</summary>
public sealed class CurrencyRateCache(string directory)
{
    public const int MaxBytes = 4_000_000;
    private string FilePath => Path.Combine(directory,"currency-rates.json");
    private sealed record Rate(string Code,string Value);
    private sealed record Snapshot(DateOnly? Requested,string Provider,string Base,DateOnly AsOf,DateTimeOffset RetrievedAt,Rate[] Rates);
    private sealed record CacheDocument(int Version,Snapshot[] Snapshots);
    public CurrencyCacheLoad Load(CancellationToken token = default)
    {
        if (!File.Exists(FilePath) && !File.Exists(FilePath+".bak")) return new(CurrencyRateBook.Empty,false,null);
        try { return new(Read(FilePath,token),false,null); }
        catch (Exception error) when (error is IOException or JsonException or ArithmeticException or NotSupportedException or FormatException or ArgumentException or InvalidOperationException)
        {
            if (error is NotSupportedException) return new(CurrencyRateBook.Empty,false,"Unsupported rate-cache version; original preserved");
            try { return new(Read(FilePath+".bak",token),true,"Rate cache recovered from backup"); }
            catch (Exception backup) when (backup is IOException or JsonException or ArithmeticException or NotSupportedException or FormatException or ArgumentException or InvalidOperationException)
            { return new(CurrencyRateBook.Empty,false,"Cached currency rates unavailable"); }
        }
    }
    private static CurrencyRateBook Read(string path,CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        using var stream = new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);
        if (stream.Length > MaxBytes) throw new InvalidDataException("Rate cache exceeds size limit");
        var bytes = new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes);
        if (stream.ReadByte() != -1) throw new InvalidDataException("Rate cache changed while reading");
        var document = JsonSerializer.Deserialize<CacheDocument>(bytes,new JsonSerializerOptions{MaxDepth=10}) ?? throw new InvalidDataException("Empty rate cache");
        if (document.Version != 1) throw new NotSupportedException();
        if (document.Snapshots is null || document.Snapshots.Length > CurrencyRateBook.MaxHistoricalSnapshots+1) throw new InvalidDataException("Too many cached rate dates");
        CurrencyRateSnapshot? latest = null; var historical = new Dictionary<DateOnly,CurrencyRateSnapshot>();
        foreach (var item in document.Snapshots)
        {
            token.ThrowIfCancellationRequested();
            if (item is null || !AuditedProvider(item.Provider) || item.Base != "EUR" || item.Rates is null || item.Rates.Length > CurrencyRateSnapshot.MaxCurrencies)
                throw new InvalidDataException("Invalid cached rate identity");
            var rates = item.Rates.Select(rate=>rate is null ? throw new InvalidDataException("Null cached rate") : new KeyValuePair<string,Rational>(rate.Code,Parse(rate.Value))).ToArray();
            var snapshot = new CurrencyRateSnapshot(item.Provider,item.Base,item.AsOf,item.RetrievedAt,rates);
            if (item.Requested is { } date)
            { if (!historical.TryAdd(date,snapshot)) throw new InvalidDataException("Duplicate cached date"); }
            else if (latest is null) latest = snapshot;
            else throw new InvalidDataException("Duplicate latest currency snapshot");
        }
        return new(latest,historical);
    }
    private static bool AuditedProvider(string? provider) => provider is EcbRateClient.Provider or InforEuroRateClient.Provider;
    private static Rational Parse(string value)
    {
        if (value is null || value.Length > 256) throw new InvalidDataException("Invalid cached rate precision");
        var parts = value.Split('/');
        if (parts.Length == 1) return Rational.Parse(value);
        if (parts.Length == 2) return Rational.Parse(parts[0])/Rational.Parse(parts[1]);
        throw new InvalidDataException("Invalid cached rate");
    }
    public void Save(CurrencyRateBook book,CancellationToken token = default)
    {
        token.ThrowIfCancellationRequested();
        Directory.CreateDirectory(directory);
        using var ownership = new FileStream(FilePath+".lock",FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
        if (File.Exists(FilePath))
        {
            try
            {
                using var current = new FileStream(FilePath,FileMode.Open,FileAccess.Read,FileShare.Read);
                if (current.Length <= MaxBytes)
                {
                    using var json = JsonDocument.Parse(current,new JsonDocumentOptions{MaxDepth=10});
                    if (json.RootElement.ValueKind == JsonValueKind.Object && json.RootElement.TryGetProperty("Version",out var version) &&
                        (version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number) || number != 1)) throw new NotSupportedException("Future rate-cache version preserved");
                }
            }
            catch (JsonException) { } // A successful new download may replace a corrupt disposable cache.
        }
        Snapshot Store(DateOnly? requested,CurrencyRateSnapshot snapshot) => new(requested,snapshot.Provider,snapshot.BaseCurrency,snapshot.AsOf,snapshot.RetrievedAt,
            snapshot.Rates.OrderBy(pair=>pair.Key,StringComparer.Ordinal).Select(pair=>new Rate(pair.Key,pair.Value.ToString())).ToArray());
        var snapshots = new List<Snapshot>(); if (book.Latest is { } latest) snapshots.Add(Store(null,latest));
        snapshots.AddRange(book.Historical.OrderBy(pair=>pair.Key).Select(pair=>Store(pair.Key,pair.Value)));
        if (snapshots.Any(value=>!AuditedProvider(value.Provider) || value.Base != "EUR")) throw new InvalidDataException("Only the audited ECB/InforEuro cache format is supported");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new CacheDocument(1,snapshots.ToArray()));
        if (bytes.Length > MaxBytes) throw new InvalidDataException("Rate cache exceeds size limit");
        var temporary = FilePath+".tmp";
        if (File.Exists(temporary)) File.Delete(temporary); // Only the owned fixed staging file, under an exclusive cache-writer lock.
        try
        {
            using (var stream = new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)) { stream.Write(bytes); stream.Flush(true); }
            token.ThrowIfCancellationRequested();
            if (File.Exists(FilePath)) File.Replace(temporary,FilePath,FilePath+".bak"); else File.Move(temporary,FilePath);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
