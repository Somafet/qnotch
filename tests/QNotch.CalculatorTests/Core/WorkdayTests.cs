using Calc.Core;

namespace Calc.Core.Tests;

public class WorkdayTests
{
    private static EvaluationContext Context(string region = "DE") => new(new(2026, 10, 31), WorkdayRegion: region);
    private static LineResult Last(string source, string region = "DE") => SheetEvaluator.Evaluate(source, context: Context(region))[^1];
    [Fact]
    public void CoverageManifestMatchesTheAvailableCalendarRegimes()
    {
        using var stream = typeof(WorkdayTests).Assembly.GetManifestResourceStream("Calc.WorkdayCoverage")!;
        using var json = System.Text.Json.JsonDocument.Parse(stream);
        Assert.Equal(WorkdayCalendar.RuleVersion, json.RootElement.GetProperty("version").GetString());
        var entries = json.RootElement.GetProperty("calendars").EnumerateArray().ToArray();
        Assert.Equal(WorkdayCalendar.SupportedRegions, entries.Select(entry => entry.GetProperty("id").GetString()));
        foreach (var entry in entries)
        {
            var calendar = new WorkdayCalendar(entry.GetProperty("id").GetString());
            Assert.Equal(calendar.FirstYear, entry.GetProperty("firstYear").GetInt32());
            Assert.Equal(calendar.LastYear, entry.GetProperty("lastYear").GetInt32());
        }
    }
    [Theory]
    [InlineData("1 mar 2027 + 10 working days", "2027-03-15")]
    [InlineData("1 jun 2027 - 15 working days", "2027-05-10")]
    [InlineData("workdays between 1 mar 2027 and 31 mar 2027", "21")]
    [InlineData("working days in march 2027", "21")]
    [InlineData("working days in december 2027", "23")]
    [InlineData("20 dec 2027 + 5 working days", "2027-12-27")]
    [InlineData("holidays=[24 dec,31 dec]\n20 dec 2027 + 5 working days", "2027-12-28")]
    [InlineData("holidays=[24 dec,31 dec]\nworking days in december 2027", "21")]
    [InlineData("holidays=[]\n20 dec 2027 + 5 business days", "2027-12-27")]
    [InlineData("holidays=[2027-12-24]\n20 dec 2028 + 5 workdays", "2028-12-29")]
    [InlineData("2027-03-27 + 0 working days", "2027-03-27")]
    [InlineData("2027-03-25 + 1 working day", "2027-03-30")]
    [InlineData("2027-03-30 - 1 working day", "2027-03-25")]
    [InlineData("workdays between 2027-03-31 and 2027-03-01", "-21")]
    [InlineData("workdays between 2027-03-01 and 2027-03-01", "1")]
    [InlineData("workdays between 2027-03-27 and 2027-03-27", "0")]
    [InlineData("in 2 working days", "2026-11-03")]
    [InlineData("2 working days ago", "2026-10-29")]
    public void DocumentedAndBoundaryExamples(string source, string expected)
    { var result = Last(source); Assert.Null(result.Error); Assert.Equal(expected, result.Display); }

    [Fact]
    public void OfficialGermanAndFederalTablesAreIndependentDateOracles()
    {
        Assert.Equal(new[] { "2026-01-01", "2026-04-03", "2026-04-06", "2026-05-01", "2026-05-14", "2026-05-25", "2026-10-03", "2026-12-25", "2026-12-26" },
            new WorkdayCalendar("DE").Holidays(2026).Select(value => value.Date.ToString("yyyy-MM-dd")));
        var de = new WorkdayCalendar("DE").Holidays(2027).Select(value => value.Date.ToString("yyyy-MM-dd")).ToArray();
        Assert.Equal(new[] { "2027-01-01", "2027-03-26", "2027-03-29", "2027-05-01", "2027-05-06", "2027-05-17", "2027-10-03", "2027-12-25", "2027-12-26" }, de);
        var us = new WorkdayCalendar("US").Holidays(2027).Select(value => value.Date.ToString("yyyy-MM-dd")).ToArray();
        Assert.Equal(new[] { "2027-01-01", "2027-01-18", "2027-02-15", "2027-05-31", "2027-06-18", "2027-07-05", "2027-09-06", "2027-10-11", "2027-11-11", "2027-11-25", "2027-12-24", "2027-12-31" }, us);
        Assert.Equal(new[] { "2026-01-01", "2026-01-19", "2026-02-16", "2026-05-25", "2026-06-19", "2026-07-03", "2026-09-07", "2026-10-12", "2026-11-11", "2026-11-26", "2026-12-25" },
            new WorkdayCalendar("US").Holidays(2026).Select(value => value.Date.ToString("yyyy-MM-dd")));
        // OPM lists New Year 2028's observance under 2028; it belongs to calendar year 2027 above.
        Assert.Equal(new[] { "2028-01-17", "2028-02-21", "2028-05-29", "2028-06-19", "2028-07-04", "2028-09-04", "2028-10-09", "2028-11-10", "2028-11-23", "2028-12-25" },
            new WorkdayCalendar("US").Holidays(2028).Select(value => value.Date.ToString("yyyy-MM-dd")));
        Assert.Equal("2027-12-27", Last("2027-12-23 + 1 working day", "US").Display);
        Assert.Equal("2028-01-03", Last("2027-12-30 + 1 working day", "US").Display);
        Assert.Equal("2027-12-31", Last("2027-12-30 + 1 working day", "DE").Display);
    }
    [Fact]
    public void CalendarContextAndCustomDateDependenciesInvalidateOnlyConsumers()
    {
        var session = new SheetEvaluationSession();
        const string source = "holidays=[24 dec]\nlead=1 working day\n2027-12-23+lead\n2+2";
        Assert.Equal("2027-12-27", session.Evaluate(source, context: Context())[2].Display);
        var changed = session.Evaluate(source.Replace("24 dec", "23 dec"), context: Context());
        Assert.Equal("2027-12-24", changed[2].Display); Assert.Equal(new[] { 0 }, changed[1].Dependencies);
        Assert.Equal(1, session.LastStatistics.ReusedResults);
        Assert.Equal("2027-12-27", session.Evaluate(source, context: Context("US"))[2].Display);
        var unchanged = session.Evaluate(source, context: Context("US") with { Today = new(2026, 11, 1) });
        Assert.Equal(4, session.LastStatistics.ReusedResults);
        Assert.All(unchanged, value => Assert.Null(value.Error));
        session.Evaluate("2027-12-23+1 working day\n4", context: Context("ZZ"));
        Assert.Equal("2027-12-24", session.Evaluate("2027-12-23+1 working day\n4", context: Context())[0].Display);
    }
    [Fact]
    public void HolidayScopeIsPrecedingSourceAndOffsetsCaptureTheirCalendar()
    {
        var results = SheetEvaluator.Evaluate("lead=1 working day\nholidays=[24 dec]\n2027-12-23+lead\n2027-12-23+1 working day\nholidays=[]\n2027-12-23+1 working day", context: Context());
        Assert.All(results, value => Assert.Null(value.Error));
        Assert.Equal("2027-12-24", results[2].Display); Assert.Equal("2027-12-27", results[3].Display); Assert.Equal("2027-12-24", results[5].Display);
        Assert.Equal(new[] { 1 }, results[3].Dependencies); Assert.Equal(new[] { 4 }, results[5].Dependencies);
    }
    [Fact]
    public void NestedFunctionsReadTheCallingLinesHolidayScopeAndCurrentRegion()
    {
        const string source = "f(n)=g(n)\ng(n)=n working days\nholidays=[24 dec]\n2027-12-23+f(1)";
        var session = new SheetEvaluationSession();
        var result = session.Evaluate(source, context: Context()); Assert.Equal("2027-12-27", result[^1].Display);
        Assert.Equal(new[] { 2 }, result[^1].Dependencies);
        Assert.Contains(result[^1].Explanation, step => step.Operation == "working days" && step.Assumption!.Contains("Germany"));
        Assert.Equal("2027-12-24", session.Evaluate(source.Replace("[24 dec]", "[]"), context: Context())[^1].Display);
        Assert.Equal("2027-12-27", session.Evaluate(source.Replace("[24 dec]", "[]"), context: Context("US"))[^1].Display);
    }
    [Fact]
    public void RandomWeekdayCountsMatchAnIndependentDailyEnumerator()
    {
        var random = new Random(7331);
        for (var trial = 0; trial < 500; trial++)
        {
            var start = new DateOnly(2023, 1, 1).AddDays(random.Next(1000)); var end = start.AddDays(random.Next(400));
            var dates = new HashSet<DateOnly> { new(start.Year, 12, 24), new(start.Year + 1, 12, 24) };
            var expected = Enumerable.Range(start.DayNumber, end.DayNumber - start.DayNumber + 1).Select(DateOnly.FromDayNumber)
                .Count(date => date.DayOfWeek is not DayOfWeek.Saturday and not DayOfWeek.Sunday && !dates.Contains(date));
            var result = Last($"holidays=[24 dec]\nworkdays between {start:yyyy-MM-dd} and {end:yyyy-MM-dd}", "WEEKDAYS");
            Assert.Null(result.Error); Assert.Equal(expected.ToString(), result.Display);
        }
    }
    [Fact]
    public void ShiftsAndCountsMatchDailyEnumerationOfTheOfficial2027GermanDates()
    {
        // A fixed table from official publications; this oracle does not call the holiday generator.
        var closed = new HashSet<DateOnly> { new(2027,1,1), new(2027,3,26), new(2027,3,29), new(2027,5,1),
            new(2027,5,6), new(2027,5,17), new(2027,10,3), new(2027,12,25), new(2027,12,26), new(2027,12,24) };
        bool Open(DateOnly date) => (int)date.DayOfWeek is >= 1 and <= 5 && !closed.Contains(date);
        var random = new Random(2727);
        for (var trial = 0; trial < 400; trial++)
        {
            var start = new DateOnly(2027,1,31).AddDays(random.Next(300)); var amount = random.Next(-20,21);
            var expected = start; var remaining = Math.Abs(amount);
            while (remaining > 0) { expected = expected.AddDays(Math.Sign(amount)); if (Open(expected)) remaining--; }
            var actual = Last($"holidays=[24 dec]\n{start:yyyy-MM-dd} + ({amount}) working days");
            Assert.Null(actual.Error); Assert.Equal(expected, actual.Value!.Value.Date);
            var end = start.AddDays(random.Next(90));
            var count = Enumerable.Range(start.DayNumber, end.DayNumber-start.DayNumber+1).Select(DateOnly.FromDayNumber).Count(Open);
            Assert.Equal(count.ToString(), Last($"holidays=[24 dec]\nworkdays between {start:yyyy-MM-dd} and {end:yyyy-MM-dd}").Display);
        }
    }
    [Fact]
    public void CustomDateSnapshotsPropagateClockReadsAndStaticFunctionsStayIndependent()
    {
        var session = new SheetEvaluationSession();
        const string source = "f(x)=x+1\nholidays=[today]\n2027-03-01+1 working day\nf(4)";
        var first = session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: Context() with { Today = new(2027,3,2) });
        Assert.True(first.UsesCurrentDate); Assert.False(first.UsesCurrentInstant); Assert.False(first.RequiresSecondRefresh);
        Assert.Equal("2027-03-03", first.Results[2].Display);
        var next = session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: Context() with { Today = new(2027,3,3) });
        Assert.Equal("2027-03-02", next.Results[2].Display); Assert.Equal("5", next.Results[3].Display);
        Assert.Equal(1, session.LastStatistics.ReusedResults); // Only the static numeric call has a result to reuse.
        Assert.Empty(next.Results[3].Dependencies);
        var unavailable = session.EvaluateWithFunctions("f(x)=x+1\nholidays=[3]\nf(4)", FunctionLibrary.Empty, [], context: Context("ZZ"));
        Assert.Equal("5", unavailable.Results[^1].Display);
    }
    [Theory]
    [InlineData("2027-01-01+1.5 working days")]
    [InlineData("2027-01-01+1% working days")]
    [InlineData("2027-01-01+10001 working days")]
    [InlineData("2021-01-01+1 working day")]
    [InlineData("2099-12-31+1 working day")]
    [InlineData("1 working day in h")]
    [InlineData("1 working day+1 day")]
    [InlineData("holidays=[31 feb]\n2027-01-01+1 working day")]
    [InlineData("holidays=[3]\n2027-01-01+1 working day")]
    [InlineData("holidays=[2027-02-29]\n2027-01-01+1 working day")]
    public void InvalidOrUnavailableInputsAreExplicit(string source) => Assert.NotNull(Last(source).Error);

    [Fact]
    public void AnnualLeapDayIsSkippedInNonLeapYearsAndExactDatesDoNotRecur()
    {
        Assert.Equal("2024-03-01", Last("holidays=[29 feb]\n2024-02-28+1 working day").Display);
        Assert.Equal("2023-03-01", Last("holidays=[29 feb]\n2023-02-28+1 working day").Display);
        Assert.Equal("2028-12-27", Last("holidays=[2027-12-24]\n2028-12-22+1 working day").Display);
        var set = Last("[24 dec,2027-12-31,24 dec]").Value!.Value.Holidays;
        Assert.Equal(2, set.Dates.Count); Assert.Equal(set, Last(set.ToString()).Value!.Value.Holidays);
    }
    [Fact]
    public void CancellationAndOutputTypesRemainBounded()
    {
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("2027-01-01+5000 working days", cancellation.Token, Context()));
        Assert.NotNull(Last("[" + string.Join(',', Enumerable.Repeat("24 dec", 257)) + "]").Error);
        var period = Last("2 working days").Value!.Value;
        Assert.Equal(SheetValueKind.WorkdayPeriod, period.Kind); Assert.Throws<ArithmeticException>(() => period.Scalar);
        Assert.Equal("1 working day", Last("1 working day").Display); Assert.Equal("-1 working day", Last("-1 working day").Display);
        Assert.Equal("2027-03-15", Last("lead=5 working days*2\n1 mar 2027+lead").Display);
        Assert.Null(Last("holidays=[3]\n2+2").Error);
    }
    [Fact]
    public void HolidayDeclarationsAreNotDuplicatedAsResultsOrIncludedInNumericTotals()
    {
        var results = SheetEvaluator.Evaluate("holidays=[24 dec]\n2\n3\nsum", context: Context());
        Assert.True(results[0].IsDeclaration); Assert.Equal("", results[0].Display); Assert.NotNull(results[0].Value);
        Assert.Equal("5", results[^1].Display); Assert.NotNull(Last("holidays=7").Error);
        Assert.Equal("2", Last("f(x)=x\nf(workdays between 2027-03-01 and 2027-03-02)").Display);
    }
}
