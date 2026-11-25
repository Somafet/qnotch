using NodaTime;
using NodaTime.TimeZones;

namespace Calc.Core;

/// <summary>Immutable host-local rules. Converting captured BCL data is deferred until an expression needs it.</summary>
public sealed class LocalZoneSnapshot
{
    private readonly Lazy<DateTimeZone> rules;
    public string Version { get; }
    public DateTimeZone Rules => rules.Value;
    public LocalZoneSnapshot(DateTimeZone zone, string version)
    {
        ArgumentNullException.ThrowIfNull(zone); ArgumentException.ThrowIfNullOrWhiteSpace(version);
        Version = version; rules = new(() => zone);
    }
    private LocalZoneSnapshot(TimeZoneInfo zone)
    {
        Version = "TimeZoneInfo:" + zone.Id + ":" + FunctionLibrary.Hash(zone.ToSerializedString());
        rules = new(() => BclDateTimeZone.FromTimeZoneInfo(zone));
    }
    public static LocalZoneSnapshot FromTimeZoneInfo(TimeZoneInfo zone)
    { ArgumentNullException.ThrowIfNull(zone); return new(zone); }
}
