using System.Globalization;
using System.Numerics;

namespace Calc.Core;

public enum PracticalKind { HeartRateZones, Pace, ClockTime }
public sealed record HeartRateZone(int Number, int Low, int High);

/// <summary>
/// Presentation of a practical-helper result. A pace or clock time keeps its exact magnitude in <see cref="Original"/> and arithmetic uses that magnitude
/// (the m:ss rounding is display only); heart-rate zones carry no single magnitude and are excluded from arithmetic and block totals.
/// </summary>
public sealed class PracticalValue
{
    public PracticalKind Kind { get; }
    public NumericValue? Original { get; }
    public IReadOnlyList<HeartRateZone> Zones { get; }
    public string Display { get; }
    public string CopyText => Display;
    public bool IsApproximate => Original?.IsApproximate == true;
    private PracticalValue(PracticalKind kind, NumericValue? original, IReadOnlyList<HeartRateZone> zones, string display)
    { Kind = kind; Original = original; Zones = zones; Display = display; }
    internal static PracticalValue ForZones(IEnumerable<HeartRateZone> zones)
    {
        var copy = zones.ToArray();
        return new(PracticalKind.HeartRateZones, null, Array.AsReadOnly(copy), string.Join(" · ", copy.Select(zone => "Z" + zone.Number.ToString(CultureInfo.InvariantCulture) + " " + zone.Low.ToString(CultureInfo.InvariantCulture) + "–" + zone.High.ToString(CultureInfo.InvariantCulture))));
    }
    /// <summary>Seconds per kilometre in <paramref name="original"/>; shown per kilometre and per mile.</summary>
    internal static PracticalValue ForPace(NumericValue original, Rational secondsPerMetre) => new(PracticalKind.Pace, original, [],
        (original.IsApproximate ? "≈ " : "") + Clock(secondsPerMetre * new Rational(1000, 1)) + " /km · " + Clock(secondsPerMetre * new Rational(1609344, 1000)) + " /mi");
    internal static PracticalValue ForClock(NumericValue original, Rational seconds) => new(PracticalKind.ClockTime, original, [], (original.IsApproximate ? "≈ " : "") + Clock(seconds));
    /// <summary>m:ss below one hour, h:mm:ss from one hour; whole seconds, halves away from zero.</summary>
    internal static string Clock(Rational seconds)
    {
        var whole = Round(seconds); var negative = whole.Sign < 0; whole = BigInteger.Abs(whole);
        var hours = BigInteger.DivRem(whole, 3600, out var rest); var minutes = BigInteger.DivRem(rest, 60, out var secs);
        var text = hours.IsZero ? minutes.ToString(CultureInfo.InvariantCulture) + ":" + secs.ToString("00", CultureInfo.InvariantCulture)
            : hours.ToString(CultureInfo.InvariantCulture) + ":" + minutes.ToString("00", CultureInfo.InvariantCulture) + ":" + secs.ToString("00", CultureInfo.InvariantCulture);
        return negative ? "-" + text : text;
    }
    internal static BigInteger Round(Rational value)
    {
        var twice = BigInteger.Abs(value.Numerator) * 2 + value.Denominator;
        var magnitude = BigInteger.Divide(twice, value.Denominator * 2);
        return value.Numerator.Sign < 0 ? -magnitude : magnitude;
    }
}
