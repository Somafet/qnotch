namespace Calc.Windows;

/// <summary>One deadline at the next local date boundary, including skipped/ambiguous midnights.</summary>
public static class DateRefreshSchedule
{
    public static TimeSpan Delay(DateTimeOffset now, TimeZoneInfo zone)
    {
        var local = TimeZoneInfo.ConvertTime(now, zone);
        var next = DateTime.SpecifyKind(local.Date.AddDays(1), DateTimeKind.Unspecified);
        // Some zones shift at midnight or skip a whole civil day. Bound the search to two days.
        for (var minute = 0; zone.IsInvalidTime(next); minute++)
        {
            if (minute >= 2880) throw new InvalidOperationException("No local date boundary within two days");
            next = next.AddMinutes(1);
        }
        var offset = zone.IsAmbiguousTime(next) ? zone.GetAmbiguousTimeOffsets(next).Max() : zone.GetUtcOffset(next);
        var remaining = new DateTimeOffset(next, offset) - now;
        return remaining < TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : remaining;
    }
}
