using System.Globalization;
using NodaTime;

namespace Calc.Core;

/// <summary>A Gregorian local date and clock reading, with no implied zone or instant.</summary>
public readonly record struct LocalTimestamp
{
    public DateTime Value { get; }
    public LocalTimestamp(DateTime value) => Value = DateTime.SpecifyKind(value, DateTimeKind.Unspecified);
    public override string ToString() => Value.ToString("yyyy-MM-dd'T'HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture).TrimEnd('.');
}

/// <summary>An instant plus the zone rules used to present and shift it. No clock or I/O.</summary>
public readonly record struct ZonedMoment
{
    public Instant Instant { get; }
    internal DateTimeZone Zone { get; }
    public string ZoneId => Zone.Id;
    public string RuleVersion { get; }
    internal ZonedMoment(Instant instant, DateTimeZone zone, string version)
    {
        const string rangeError = "Timestamp range exceeded (years 0001 through 9999 in both UTC and local time)";
        if (instant < Instant.FromUtc(1, 1, 1, 0, 0) || instant > Instant.FromDateTimeUtc(DateTime.SpecifyKind(DateTime.MaxValue, DateTimeKind.Utc))) throw new ArithmeticException(rangeError);
        try { if (instant.InZone(zone).Year is < 1 or > 9999) throw new ArithmeticException(rangeError); }
        catch (ArgumentOutOfRangeException) { throw new ArithmeticException(rangeError); }
        Instant = instant; Zone = zone; RuleVersion = version;
    }
    internal ZonedMoment Checked() => Zone is null ? throw new ArithmeticException("Zoned timestamp has no zone") : this;
    public override string ToString()
    {
        var zoned = Instant.InZone(Zone); var offset = zoned.Offset.Seconds;
        var magnitude = Math.Abs(offset);
        var suffix = offset == 0 ? "Z" : (offset < 0 ? "-" : "+") + $"{magnitude / 3600:D2}:{magnitude / 60 % 60:D2}" +
            (magnitude % 60 == 0 ? "" : $":{magnitude % 60:D2}");
        return new LocalTimestamp(zoned.LocalDateTime.ToDateTimeUnspecified()) + suffix;
    }
}

[Flags]
internal enum ContextDependency { None = 0, Date = 1, Instant = 2, ZoneRules = 4, LocalZone = 8, SecondTick = 16, WorkdayCalendar = 32, CurrencyRates = 64, PayrollRegion = 128, Uuid = 256, DisplayCurrency = 512, Dice = 1024 }
internal sealed class ContextReads
{
    internal ContextDependency Dependencies;
    private HashSet<UuidRequest>? uuidRequests;
    internal HashSet<UuidRequest> UuidRequests => uuidRequests ??= [];
    internal int UuidRequestCount => uuidRequests?.Count ?? 0;
    private HashSet<DateOnly?>? currencyRequests;
    internal HashSet<DateOnly?> CurrencyRequests => currencyRequests ??= [];
    internal int CurrencyRequestCount => currencyRequests?.Count ?? 0;
}
