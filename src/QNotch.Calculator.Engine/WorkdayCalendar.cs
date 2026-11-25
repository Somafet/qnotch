using System.Globalization;

namespace Calc.Core;

public readonly record struct HolidayDate(int Month, int Day, int? Year = null)
{
    internal HolidayDate Checked()
    {
        if (Year is < 1 or > 9999 || Month is < 1 or > 12 || Day < 1 || Day > DateTime.DaysInMonth(Year ?? 2000, Month))
            throw new ArithmeticException("Invalid holiday date");
        return this;
    }
    public override string ToString() => Year is { } year ? $"{year:D4}-{Month:D2}-{Day:D2}" : new DateOnly(2000, Month, Day).ToString("d MMM", CultureInfo.InvariantCulture);
}

/// <summary>Immutable, bounded annual/exact dates. No OS, network or mutable calendar state.</summary>
public sealed class HolidaySet : IEquatable<HolidaySet>
{
    public const int MaxDates = 256;
    public static HolidaySet Empty { get; } = new([]);
    public IReadOnlyList<HolidayDate> Dates { get; }
    internal string Key { get; }
    public HolidaySet(IEnumerable<HolidayDate> dates)
    {
        var values = new List<HolidayDate>();
        foreach (var date in dates)
        {
            if (values.Count >= MaxDates) throw new ArithmeticException("Holiday list exceeds 256 dates");
            values.Add(date.Checked());
        }
        var sorted = values.Distinct().OrderBy(date => date.Year ?? 0).ThenBy(date => date.Month).ThenBy(date => date.Day).ToArray();
        Dates = Array.AsReadOnly(sorted); Key = string.Join(',', sorted);
    }
    public bool Equals(HolidaySet? other) => other is not null && Key == other.Key;
    public override bool Equals(object? obj) => obj is HolidaySet other && Equals(other);
    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Key);
    public override string ToString() => "[" + string.Join(", ", Dates) + "]";
}

public sealed record HolidayOccurrence(DateOnly Date, string Name);

/// <summary>Current-rule projections, not a prediction of future legislation or an employment schedule.</summary>
public sealed class WorkdayCalendar : IEquatable<WorkdayCalendar>
{
    public const string RuleVersion = "2026-10-31";
    public string Region { get; }
    public HolidaySet CustomHolidays { get; }
    public string Scope => Region switch { "DE" => "Germany nationwide holidays", "US" => "US federal Monday-Friday observance", _ => "Weekdays only; no regional holidays" };
    public int FirstYear => Region == "WEEKDAYS" ? 1 : 2022;
    public int LastYear => Region == "WEEKDAYS" ? 9999 : 2099;
    public static IReadOnlyList<string> SupportedRegions { get; } = Array.AsReadOnly(new[] { "DE", "US", "WEEKDAYS" });
    public WorkdayCalendar(string? region, HolidaySet? holidays = null)
    {
        Region = region?.ToUpperInvariant() ?? "";
        if (!SupportedRegions.Contains(Region)) throw new ArithmeticException($"Holiday calendar unavailable for {(Region.Length == 0 ? "unspecified region" : Region)}");
        CustomHolidays = holidays ?? HolidaySet.Empty;
    }
    internal void Check(DateOnly date)
    {
        if (date.Year < FirstYear || date.Year > LastYear) throw new ArithmeticException($"{Region} holiday rules cover {FirstYear}–{LastYear} only (current-rule projection)");
    }
    public IReadOnlyList<HolidayOccurrence> Holidays(int year)
    {
        if (year < FirstYear || year > LastYear) throw new ArithmeticException($"{Region} holiday year unavailable");
        var values = new List<HolidayOccurrence>();
        void Fixed(int month, int day, string name, int? originYear = null)
        {
            var date = new DateOnly(originYear ?? year, month, day);
            if (Region == "US") date = date.AddDays(date.DayOfWeek == DayOfWeek.Saturday ? -1 : date.DayOfWeek == DayOfWeek.Sunday ? 1 : 0);
            if (date.Year == year) values.Add(new(date, name));
        }
        void Nth(int month, DayOfWeek day, int occurrence, string name)
        {
            var first = new DateOnly(year, month, 1);
            values.Add(new(first.AddDays(((int)day - (int)first.DayOfWeek + 7) % 7 + (occurrence - 1) * 7), name));
        }
        if (Region == "DE")
        {
            Fixed(1, 1, "New Year"); Fixed(5, 1, "Labour Day"); Fixed(10, 3, "German Unity");
            Fixed(12, 25, "Christmas"); Fixed(12, 26, "Second Christmas Day");
            var easter = Easter(year);
            foreach (var (offset, name) in new[] { (-2, "Good Friday"), (1, "Easter Monday"), (39, "Ascension"), (50, "Whit Monday") })
                values.Add(new(easter.AddDays(offset), name));
        }
        else if (Region == "US")
        {
            Fixed(1, 1, "New Year");
            // A Saturday January 1 is observed in the preceding calendar year.
            if (year < 9999) Fixed(1, 1, "New Year", year + 1);
            Nth(1, DayOfWeek.Monday, 3, "Martin Luther King Jr. Day"); Nth(2, DayOfWeek.Monday, 3, "Washington's Birthday");
            var mayEnd = new DateOnly(year, 5, 31);
            values.Add(new(mayEnd.AddDays(-((int)mayEnd.DayOfWeek - (int)DayOfWeek.Monday + 7) % 7), "Memorial Day"));
            Fixed(6, 19, "Juneteenth"); Fixed(7, 4, "Independence Day");
            Nth(9, DayOfWeek.Monday, 1, "Labour Day"); Nth(10, DayOfWeek.Monday, 2, "Columbus Day");
            Fixed(11, 11, "Veterans Day"); Nth(11, DayOfWeek.Thursday, 4, "Thanksgiving"); Fixed(12, 25, "Christmas");
        }
        foreach (var custom in CustomHolidays.Dates)
            if ((custom.Year is null || custom.Year == year) && custom.Day <= DateTime.DaysInMonth(year, custom.Month))
                values.Add(new(new(year, custom.Month, custom.Day), "Custom holiday"));
        return Array.AsReadOnly(values.DistinctBy(value => value.Date).OrderBy(value => value.Date).ToArray());
    }
    private static DateOnly Easter(int year)
    {
        // Gregorian ecclesiastical computus (integer arithmetic, not astronomical full moons).
        var a = year % 19; var b = year / 100; var c = year % 100; var d = b / 4; var e = b % 4;
        var f = (b + 8) / 25; var g = (b - f + 1) / 3; var h = (19 * a + b - d - g + 15) % 30;
        var i = c / 4; var k = c % 4; var l = (32 + 2 * e + 2 * i - h - k) % 7;
        var m = (a + 11 * h + 22 * l) / 451; var n = h + l - 7 * m + 114;
        return new(year, n / 31, n % 31 + 1);
    }
    public bool Equals(WorkdayCalendar? other) => other is not null && Region == other.Region && CustomHolidays.Equals(other.CustomHolidays);
    public override bool Equals(object? obj) => obj is WorkdayCalendar other && Equals(other);
    public override int GetHashCode() => HashCode.Combine(Region, CustomHolidays);
}

public sealed record WorkdayPeriod(int Count, WorkdayCalendar Calendar)
{
    public const int MaxCount = 10000;
    internal WorkdayPeriod Checked()
    {
        if (Math.Abs((long)Count) > MaxCount || Calendar is null) throw new ArithmeticException("Working-day count limit exceeded (10,000)");
        return this;
    }
    public override string ToString() => Count.ToString(CultureInfo.InvariantCulture) + (Math.Abs((long)Count) == 1 ? " working day" : " working days");
}
