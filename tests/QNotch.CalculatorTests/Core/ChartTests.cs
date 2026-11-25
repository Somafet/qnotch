using Calc.Core;

namespace Calc.Core.Tests;

public class ChartTests
{
    private static LineResult Last(string source) => SheetEvaluator.Evaluate(source)[^1];
    private static ChartValue Chart(string source) { var result = Last(source); Assert.Null(result.Error); return result.Value!.Value.Chart; }
    private static string[] Labels(ChartValue chart) => chart.Items.Select(item => item.Label).ToArray();

    [Theory]
    [InlineData("bar chart of [10, 20, 30]", ChartKind.Bar, "60")]
    [InlineData("bar chart [10, 20, 30]", ChartKind.Bar, "60")]
    [InlineData("pie chart of [1, 3]", ChartKind.Pie, "4")]
    [InlineData("trend chart of [1, 3, 2]", ChartKind.Trend, "3 points")]
    [InlineData("line chart of [1, 3, 2]", ChartKind.Trend, "3 points")]
    [InlineData("BAR CHART OF [2, 2]", ChartKind.Bar, "4")]
    [InlineData("v = [1, 2]\nbar chart of v", ChartKind.Bar, "3")]
    public void ListFormsShowTotalOrCount(string source, ChartKind kind, string display)
    {
        var result = Last(source);
        Assert.Equal(kind, result.Value!.Value.Chart.Kind); Assert.Equal(display, result.Display);
    }

    [Fact]
    public void MagnitudesFollowTheData()
    {
        var chart = Chart("bar chart of [10, -20, 30]");
        Assert.Equal([10d, -20, 30], chart.Items.Select(item => item.Magnitude));
        Assert.Equal(["1", "2", "3"], Labels(chart));
    }

    [Fact]
    public void PrecedingLinesUseNamesAndProseLabels()
    {
        var chart = Chart("# Spending\nrent = 1200\nGroceries 300\n\"Going out\" 100\n50\nbar chart");
        Assert.Equal(["rent", "Groceries", "Going out", "L5"], Labels(chart));
        Assert.Equal([1200d, 300, 100, 50], chart.Items.Select(item => item.Magnitude));
        Assert.Equal("1650", Chart("rent = 1200\nGroceries 300\n\"Going out\" 100\n50\nbar chart").Total);
    }

    [Fact]
    public void BlocksBoundTheData()
    {
        var chart = Chart("1\n2\n\n3\n4\npie chart");
        Assert.Equal([3d, 4], chart.Items.Select(item => item.Magnitude));
    }

    [Fact]
    public void TagsSelectLikeSum() => Assert.Equal([5d, 7], Chart("5 #food\n6\n7 #food\n\nbar chart #food").Items.Select(item => item.Magnitude));

    [Fact]
    public void ChartLinesNeverJoinAggregatesOrEachOther()
    {
        Assert.Equal("3", Last("1\n2\nbar chart\nsum").Display);
        Assert.Equal("3", Last("1\n2\npie chart of [-1]\nsum").Display);
        var second = Chart("1\n2\nbar chart\npie chart");
        Assert.Equal([1d, 2], second.Items.Select(item => item.Magnitude));
    }

    [Fact]
    public void ListsAndSolveLinesInABlockAreSkipped() => Assert.Equal([2d], Chart("[1, 2]\nsolve x = 1\n2\nbar chart").Items.Select(item => item.Magnitude));

    [Fact]
    public void UnitsAreConvertedToTheFirstAndKeptInLabels()
    {
        var chart = Chart("bar chart of [1 m, 50 cm]");
        Assert.Equal([1d, .5], chart.Items.Select(item => item.Magnitude));
        Assert.Equal("1 m", chart.Items[0].Display); Assert.Equal("0.5 m", chart.Items[1].Display);
        Assert.Equal("1.5 m", chart.Total);
    }

    [Fact]
    public void MoneyKeepsItsCurrency()
    {
        var chart = Chart("bar chart of [$10, $5.50]");
        Assert.Equal([10d, 5.5], chart.Items.Select(item => item.Magnitude));
        Assert.Contains("15.5", chart.Total);
    }

    [Fact]
    public void ApproximateInputsAreMarked()
    {
        Assert.True(Chart("bar chart of [sin(1), 1]").IsApproximate);
        Assert.StartsWith("≈", Last("bar chart of [sin(1), 1]").Display);
        Assert.False(Chart("bar chart of [1, 2]").IsApproximate);
    }

    [Theory]
    [InlineData("bar chart of [1 m, 2 s]")]
    [InlineData("bar chart of [1, $2]")]
    [InlineData("bar chart of [$1, EUR 2]")]
    [InlineData("pie chart of [1, -2]")]
    [InlineData("pie chart of [0, 0]")]
    [InlineData("trend chart of [1]")]
    [InlineData("bar chart of []")]
    [InlineData("bar chart of [[1, 2], [3, 4]]")]
    [InlineData("x = 5\nbar chart of x")]
    [InlineData("bar chart")]
    [InlineData("\n\npie chart")]
    [InlineData("2026-01-01\nbar chart")]
    public void BadDataIsAnExplicitError(string source)
    {
        var result = Last(source);
        Assert.NotNull(result.Error); Assert.Null(result.Value);
    }

    [Fact]
    public void BoundsRefuseRatherThanTruncate()
    {
        static string List(int count) => "[" + string.Join(", ", Enumerable.Repeat("1", count)) + "]";
        Assert.Equal(64, Chart("bar chart of " + List(64)).Items.Count);
        Assert.Contains("at most 64", Last("bar chart of " + List(65)).Error);
        Assert.Equal(512, Chart("trend chart of " + List(512)).Items.Count);
        Assert.Contains("at most 512", Last("trend chart of " + List(513)).Error);
    }

    [Theory]
    [InlineData("bar chart monthly")]
    [InlineData("the bar chart")]
    [InlineData("pie chart of the month")]
    [InlineData("chart")]
    public void ProseStaysProse(string source)
    {
        var result = Last(source);
        Assert.Null(result.Value); Assert.Null(result.Error);
    }

    [Theory]
    [InlineData("bar chart 5", "5")]
    [InlineData("3 bar", "3 bar")]
    [InlineData("bar = 3\nbar + 1", "4")]
    [InlineData("bar = 3\nbar", "3")]
    public void UnitsLabelsAndVariablesKeepWorking(string source, string display) => Assert.Equal(display, Last(source).Display);

    [Fact]
    public void VariableNamedLikeTheSentenceDisablesIt()
    {
        var result = Last("1\nbar = 2\nbar chart");
        Assert.NotEqual(SheetValueKind.Chart, result.Value?.Kind);
    }

    [Fact]
    public void ChangingALabelRebuildsTheChart()
    {
        var session = new SheetEvaluationSession();
        session.Evaluate("Rent 100\nbar chart");
        var results = session.Evaluate("Lease 100\nbar chart");
        Assert.Equal("Lease", results[1].Value!.Value.Chart.Items[0].Label);
    }

    [Fact]
    public void ChangingAnUnrelatedLineReusesTheChart()
    {
        var session = new SheetEvaluationSession();
        var first = session.Evaluate("1\n2\nbar chart\n\nnote 5");
        var second = session.Evaluate("1\n2\nbar chart\n\nnote 6");
        Assert.Same(first[2], second[2]);
    }

    [Fact]
    public void ExplanationAndAccessibilityDescribeTheData()
    {
        var result = Last("Rent 10\nFood 30\nbar chart");
        var chart = result.Value!.Value.Chart;
        Assert.Contains("Bar chart of 2 values", result.Explanation[^1].Assumption);
        Assert.Contains("Rent: 10", chart.Details);
        Assert.Equal("Rent: 10, Food: 30", result.Value!.Value.CopyText);
        Assert.Equal("Bar chart of 2 values, from Rent 10 to Food 30", chart.Description);
    }

    [Fact]
    public void SavedFunctionsChartTheirArgument()
    {
        var library = new FunctionLibrary([new("bars", ["v"], "bar chart of v")]);
        Assert.Equal(FunctionLibrary.LatestCatalogVersion, library.MinimumCatalogVersion);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("bars([1, 2])", library, []).Results;
        Assert.Equal("3", results[0].Display);
    }
}
