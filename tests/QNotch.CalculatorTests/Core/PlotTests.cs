using Calc.Core;

namespace Calc.Core.Tests;

public class PlotTests
{
    private static LineResult Last(string source) => SheetEvaluator.Evaluate(source)[^1];
    private static PlotValue Plot(string source) { var result = Last(source); Assert.Null(result.Error); return result.Value!.Value.Plot; }
    private static (double Start, double End)[] Segments(PlotValue plot) => plot.SegmentStarts.Select((start, i) =>
        (plot.X[start], plot.X[(i + 1 < plot.SegmentStarts.Count ? plot.SegmentStarts[i + 1] : plot.X.Count) - 1])).ToArray();

    [Theory]
    [InlineData("plot sin(x)", -10, 10)]
    [InlineData("plot x^2 from -2 to 2", -2, 2)]
    [InlineData("plot X^2 FROM 0 TO 1", 0, 1)]
    public void PublishedFormsPlotTheirDomain(string source, double lower, double upper)
    {
        var plot = Plot(source);
        Assert.Equal(lower, plot.X[0]); Assert.Equal(upper, plot.X[^1]);
        Assert.Equal("plot", Last(source).Display);
    }

    [Theory]
    [InlineData("plot sin(x)")]
    [InlineData("plot tan(x)")]
    [InlineData("plot 1/x")]
    [InlineData("plot sin(20x)")]
    [InlineData("plot tan(100x)")]
    [InlineData("plot ln(x)")]
    public void PointsStayBoundedOrderedAndFinite(string source)
    {
        var plot = Plot(source);
        Assert.InRange(plot.X.Count, 2, PlotValue.MaxPoints);
        Assert.Equal(plot.X.Count, plot.Y.Count);
        Assert.All(plot.Y, y => Assert.True(double.IsFinite(y)));
        Assert.True(plot.X.Zip(plot.X.Skip(1)).All(pair => pair.First < pair.Second));
        Assert.Equal(0, plot.SegmentStarts[0]);
    }

    [Fact]
    public void SamplesLieOnTheFormula()
    {
        var plot = Plot("plot x^2 from -2 to 2");
        Assert.All(plot.X.Zip(plot.Y), point => Assert.Equal(point.First * point.First, point.Second, 12));
        Assert.Equal([0], plot.SegmentStarts);
        Assert.Equal(0, plot.YLower, 12); Assert.Equal(4, plot.YUpper, 12);
        Assert.False(plot.YLimited);
    }

    [Fact]
    public void TangentBreaksAtEachPoleAndKeepsUsableLimits()
    {
        var plot = Plot("plot tan(x)");
        // Poles of tan on [-10, 10] are (k + 1/2)pi for k from -3 to 2.
        var poles = Enumerable.Range(-3, 6).Select(k => (k + .5) * Math.PI).ToArray();
        var segments = Segments(plot);
        Assert.Equal(poles.Length + 1, segments.Length);
        for (var i = 0; i < poles.Length; i++) Assert.True(segments[i].End < poles[i] && poles[i] < segments[i + 1].Start, $"pole {poles[i]}");
        Assert.True(plot.YLimited);
        Assert.InRange(plot.YUpper, 1, 20); Assert.InRange(plot.YLower, -20, -1);
        Assert.True(plot.Y.Max() > plot.YUpper * 10);
    }

    [Fact]
    public void ReciprocalBreaksAtZero()
    {
        var plot = Plot("plot 1/x from -1 to 3");
        var segments = Segments(plot);
        Assert.Equal(2, segments.Length);
        Assert.True(segments[0].End < 0 && segments[1].Start > 0);
    }

    [Fact]
    public void JumpWithoutPoleBreaksOnce()
    {
        // abs(x)/x is the sign function: -1 below zero, +1 above, undefined at zero.
        var plot = Plot("plot abs(x)/x from -1 to 2");
        Assert.Equal(2, plot.SegmentStarts.Count);
        Assert.Equal(-1, plot.YLower, 12); Assert.Equal(1, plot.YUpper, 12);
    }

    [Theory]
    [InlineData("plot atan(1000x) from -1 to 1")]
    [InlineData("plot tanh(50x) from -1 to 1")]
    [InlineData("plot abs(x) from -1 to 1")]
    [InlineData("plot exp(x)")]
    public void ContinuousSteepCurvesStayOneSegment(string source) => Assert.Single(Plot(source).SegmentStarts);

    [Fact]
    public void ContinuousGrowthKeepsItsWholeRange()
    {
        var plot = Plot("plot exp(x)");
        Assert.False(plot.YLimited);
        Assert.Equal(Math.Exp(10), plot.YUpper, 6);
    }

    [Fact]
    public void DomainEdgeIsRefinedTowardItsLimit()
    {
        var plot = Plot("plot sqrt(x) from -4 to 4");
        Assert.Single(plot.SegmentStarts);
        // The grid step is 1/32; eight halvings reach 1/8192 from the true edge at zero.
        Assert.InRange(plot.X[0], 0, 1d / 4096);
        Assert.Equal(2, plot.YUpper, 12);
    }

    [Fact]
    public void ConstantCurveStillHasAVerticalRange()
    {
        var plot = Plot("plot x - x + 5 from 0 to 1");
        Assert.True(plot.YLower < 5 && plot.YUpper > 5);
    }

    [Fact]
    public void SheetNamesAreConstantsAndRecalculate()
    {
        var plot = Plot("a = 3\nplot a*x from 0 to 2");
        Assert.Equal(6, plot.Y[^1], 12);
        var session = new SheetEvaluationSession();
        session.Evaluate("a = 3\nb = 1\nplot a*x from 0 to 2");
        var changed = session.Evaluate("a = 4\nb = 1\nplot a*x from 0 to 2");
        Assert.Equal(8, changed[2].Value!.Value.Plot.Y[^1], 12);
    }

    [Fact]
    public void VariableShadowsASheetVariableOfTheSameName() => Assert.Equal(4, Plot("x = 100\nplot x^2 from 0 to 2").Y[^1], 12);

    [Theory]
    [InlineData("plot x from 2 to 1")]
    [InlineData("plot x from 1 to 1")]
    [InlineData("plot sqrt(-1 - x^2)")]
    [InlineData("plot x from 1 m to 2 m")]
    [InlineData("plot x from 0 to n")]
    public void DomainProblemsAreExplicitErrors(string source)
    {
        var result = Last(source);
        Assert.NotNull(result.Error); Assert.Null(result.Value);
    }

    [Fact]
    public void AllUndefinedReadsAsSuch() => Assert.Contains("undefined", Last("plot ln(-1 - x^2)").Error);

    [Theory]
    [InlineData("plot twist")]
    [InlineData("plot the results")]
    [InlineData("plot x marks the spot")]
    [InlineData("plot")]
    public void ProseStaysProse(string source)
    {
        var result = Last(source);
        Assert.Null(result.Value); Assert.Null(result.Error);
    }

    [Theory]
    [InlineData("plot 5", "5")]
    [InlineData("plot = 3\nplot + 1", "4")]
    [InlineData("plot = 3\nplot", "3")]
    public void LabelsAndVariablesWinOverTheSentence(string source, string display) => Assert.Equal(display, Last(source).Display);

    [Fact]
    public void PlotLinesNeverJoinAggregates()
    {
        Assert.Equal("3", Last("1\n2\nplot x\nsum").Display);
        Assert.Equal("3", Last("1\n2\nplot x from 2 to 1\nsum").Display);
        Assert.Equal("3", Last("1\n2\np = plot x\nq = p\nsum").Display);
    }

    [Fact]
    public void ArithmeticOnAPlotIsAnError() => Assert.NotNull(Last("p = plot x\np + 1").Error);

    [Fact]
    public void ExplanationDisclosesSamplingAndApproximation()
    {
        var result = Last("plot sin(x)");
        var assumption = result.Explanation[^1].Assumption!;
        Assert.StartsWith("Approximate", assumption);
        Assert.Contains("Sampled curve", assumption); Assert.Contains("radians", assumption);
        var plot = result.Value!.Value.Plot;
        Assert.Contains("257 uniform samples", plot.Details);
        Assert.Contains(plot.X.Count + " points", result.Value!.Value.CopyText);
        Assert.Contains("sin(x)", plot.Description);
    }

    [Fact]
    public void EqualSourceGivesAnEqualValue() => Assert.Equal(Last("plot tan(x)").Value, Last("plot tan(x)").Value);

    [Fact]
    public void SavedFunctionBodiesParseCanonicalizeAndEvaluate()
    {
        var library = new FunctionLibrary([new("wave", ["a"], "plot a*sin(x) from 0 to 1")]);
        Assert.Equal(FunctionLibrary.LatestCatalogVersion, library.MinimumCatalogVersion);
        var result = new SheetEvaluationSession().EvaluateWithFunctions("wave(2)", library, []).Results[0];
        Assert.Equal(SheetValueKind.Plot, result.Value!.Value.Kind);
        Assert.Equal(2 * Math.Sin(1), result.Value!.Value.Plot.Y[^1], 12);
    }

    [Fact]
    public void CancellationStopsSampling()
    {
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("plot sin(x)", cancelled.Token));
    }

    [Fact]
    public void ManyPlotsShareTheSheetBudget()
    {
        // Each tan plot needs more than a thousand samples, so a thousand lines exceed the 500,000 step sheet budget.
        Assert.Throws<SheetComputationLimitException>(() => SheetEvaluator.Evaluate(string.Join('\n', Enumerable.Repeat("plot tan(x)", 1000))));
    }
}
