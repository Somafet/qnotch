using System.Globalization;

namespace Calc.Core;

/// <summary>Immutable sampled curve: finite points in x order, split into segments at undefined samples and jumps. The host draws it; nothing here depends on a pixel size.</summary>
public sealed class PlotValue : IEquatable<PlotValue>
{
    public const int MaxPoints = 512;
    private readonly double[] x, y; private readonly int[] starts; private readonly int hash;
    public string Formula { get; }
    public double Lower { get; }
    public double Upper { get; }
    public double YLower { get; }
    public double YUpper { get; }
    /// <summary>The y limits exclude values near a pole or jump instead of spanning them.</summary>
    public bool YLimited { get; }
    /// <summary>More sharp changes were found than the sampling bound can resolve.</summary>
    public bool Undersampled { get; }
    public IReadOnlyList<double> X { get; }
    public IReadOnlyList<double> Y { get; }
    /// <summary>Index of the first point of each drawn segment.</summary>
    public IReadOnlyList<int> SegmentStarts { get; }
    internal PlotValue(string formula, double lower, double upper, double[] xs, double[] ys, int[] segments, double yLower, double yUpper, bool limited, bool undersampled)
    {
        if (xs.Length is 0 or > MaxPoints || xs.Length != ys.Length) throw new ArithmeticException("Plot point limit exceeded");
        Formula = formula; Lower = lower; Upper = upper; x = xs; y = ys; starts = segments; YLower = yLower; YUpper = yUpper; YLimited = limited; Undersampled = undersampled;
        X = Array.AsReadOnly(x); Y = Array.AsReadOnly(y); SegmentStarts = Array.AsReadOnly(starts);
        var code = new HashCode(); code.Add(StringComparer.Ordinal.GetHashCode(formula)); code.Add(yLower); code.Add(yUpper);
        foreach (var value in x) code.Add(value);
        foreach (var value in y) code.Add(value);
        foreach (var value in starts) code.Add(value);
        hash = code.ToHashCode();
    }
    public static string Number(double value) => (Math.Abs(value) < 1e-12 ? 0d : value).ToString("G4", CultureInfo.InvariantCulture);
    private string Domain => "[" + Number(Lower) + ", " + Number(Upper) + "]";
    private string Range => Number(YLower) + " to " + Number(YUpper);
    public string Display => "plot";
    public string CopyText => "plot " + Formula + " on " + Domain + ": y from " + Range + ", " + x.Length + " points";
    public string Summary => "Sampled on " + Domain + "; y shown from " + Range + (YLimited ? "\nLimits leave out values near poles or jumps" : "");
    public string Details => "Formula: " + Formula + "\nDomain: " + Domain + "\n" + x.Length + " points from " + PlotSampler.GridSamples + " uniform samples, refined near sharp changes up to " + MaxPoints + "\n" +
        starts.Length + " segment(s); a segment ends at an undefined sample or a jump\ny shown from " + Range + (YLimited ? ", robust limits that leave out values near poles or jumps" : ", the sampled extremes") +
        (Undersampled ? "\nToo many sharp changes for the sampling bound; narrow the domain with from a to b" : "");
    public string Description => "Plot of " + Formula + " for x from " + Number(Lower) + " to " + Number(Upper) + ", y shown from " + Range;
    public bool Equals(PlotValue? other) => ReferenceEquals(this, other) || other is not null && hash == other.hash && Formula == other.Formula && Lower == other.Lower && Upper == other.Upper && YLower == other.YLower && YUpper == other.YUpper &&
        x.AsSpan().SequenceEqual(other.x) && y.AsSpan().SequenceEqual(other.y) && starts.AsSpan().SequenceEqual(other.starts);
    public override bool Equals(object? obj) => obj is PlotValue other && Equals(other);
    public override int GetHashCode() => hash;
    public override string ToString() => Display;
}

/// <summary>Uniform grid, then bounded midpoint refinement where the curve moves sharply or stops being defined. Jumps are confirmed by bisection: a continuous step halves, a jump does not.</summary>
internal static class PlotSampler
{
    internal const int GridSamples = 257, MaxProbes = 2048, MaxRounds = 8, JumpDepth = 24;
    private const double SharpStep = .04, JumpStep = .2, FenceFactor = 3;
    internal static PlotValue Sample(Formula formula, string text, double lower, double upper, ExecutionBudget budget, CancellationToken token)
    {
        double At(double x) { var y = formula.Sample(x, budget, token); return double.IsFinite(y) ? y : double.NaN; }
        var step = (upper - lower) / (GridSamples - 1);
        if (!double.IsFinite(lower) || !double.IsFinite(step) || lower + step == lower) throw new ArithmeticException("Plot domain is too wide or too narrow");
        var points = new List<(double X, double Y)>(PlotValue.MaxPoints);
        for (var i = 0; i < GridSamples; i++) { var x = i == GridSamples - 1 ? upper : lower + i * step; points.Add((x, At(x))); }
        var grid = points.Select(point => point.Y).Where(double.IsFinite).Order().ToArray();
        if (grid.Length == 0) throw new ArithmeticException("Nothing to plot: the formula is undefined across this domain");
        // Quartile fences come from the uniform grid only: refinement clusters near poles and would widen them.
        var q1 = grid[(grid.Length - 1) / 4]; var q3 = grid[3 * (grid.Length - 1) / 4];
        var spread = q3 > q1 ? q3 - q1 : Math.Max(Math.Abs(q1), 1);
        var fenceLower = q1 - FenceFactor * spread; var fenceUpper = q3 + FenceFactor * spread;
        var viewLower = Math.Max(grid[0], fenceLower); var viewUpper = Math.Min(grid[^1], fenceUpper);
        var scale = viewUpper > viewLower ? viewUpper - viewLower : Math.Max(Math.Abs(viewLower), 1);
        double Clamp(double y) => Math.Clamp(y, viewLower - scale, viewUpper + scale);
        for (var round = 0; round < MaxRounds && points.Count < PlotValue.MaxPoints; round++)
        {
            var sharp = new List<(double Score, int Index)>();
            for (var i = 0; i + 1 < points.Count; i++)
            {
                token.ThrowIfCancellationRequested();
                var (a, b) = (points[i].Y, points[i + 1].Y);
                if (double.IsNaN(a) && double.IsNaN(b)) continue;
                var score = double.IsNaN(a) || double.IsNaN(b) ? 2 : Math.Abs(Clamp(b) - Clamp(a)) / scale;
                if (score > SharpStep) sharp.Add((score, i));
            }
            if (sharp.Count == 0) break;
            var chosen = sharp.OrderByDescending(item => item.Score).Take(PlotValue.MaxPoints - points.Count).Select(item => item.Index).ToHashSet();
            var refined = new List<(double X, double Y)>(PlotValue.MaxPoints);
            for (var i = 0; i < points.Count; i++)
            {
                refined.Add(points[i]);
                if (!chosen.Contains(i)) continue;
                var x = points[i].X + (points[i + 1].X - points[i].X) / 2;
                refined.Add((x, At(x)));
            }
            points = refined;
        }
        var probes = MaxProbes; var undersampled = false;
        bool Jumps((double X, double Y) a, (double X, double Y) b)
        {
            var start = Math.Abs(b.Y - a.Y);
            if (start <= JumpStep * scale) return false;
            for (var depth = 0; depth < JumpDepth; depth++)
            {
                if (probes-- <= 0) { undersampled = true; return false; }
                var x = a.X + (b.X - a.X) / 2;
                if (x == a.X || x == b.X) return true;
                var y = At(x);
                if (double.IsNaN(y)) return true;
                var (left, right) = (Math.Abs(y - a.Y), Math.Abs(b.Y - y));
                if (Math.Max(left, right) < start / 4) return false;
                if (left >= right) b = (x, y); else a = (x, y);
            }
            return true;
        }
        var xs = new List<double>(points.Count); var ys = new List<double>(points.Count); var starts = new List<int>();
        var gap = true; var broken = false;
        for (var i = 0; i < points.Count; i++)
        {
            token.ThrowIfCancellationRequested();
            if (double.IsNaN(points[i].Y)) { gap = true; broken = true; continue; }
            if (gap || Jumps(points[i - 1], points[i])) { broken |= !gap; starts.Add(xs.Count); }
            xs.Add(points[i].X); ys.Add(points[i].Y); gap = false;
        }
        var minimum = ys.Min(); var maximum = ys.Max();
        var limited = broken && (minimum < fenceLower || maximum > fenceUpper);
        var yLower = broken ? Math.Max(minimum, fenceLower) : minimum; var yUpper = broken ? Math.Min(maximum, fenceUpper) : maximum;
        if (!(yUpper > yLower)) { var margin = yLower == 0 ? 1 : Math.Abs(yLower) / 10; yLower -= margin; yUpper += margin; }
        return new(text, lower, upper, xs.ToArray(), ys.ToArray(), starts.ToArray(), yLower, yUpper, limited, undersampled);
    }
}

internal static class PlotArithmetic
{
    internal static (SheetValue Value, string Assumption) Plot(PlotExpression plot, SheetValue[] inputs, ExactArithmetic math, ExecutionBudget budget, CancellationToken token)
    {
        var constants = inputs.Length - (plot.HasDomain ? 2 : 0);
        var formula = FormulaArithmetic.Prepare(plot.Body, "x", inputs, constants).Formula;
        double lower = FormulaRoots.DefaultLower, upper = FormulaRoots.DefaultUpper;
        if (plot.HasDomain)
        {
            var from = FormulaArithmetic.Require(inputs[^2], "Domain bound"); var to = FormulaArithmetic.Require(inputs[^1], "Domain bound");
            if (math.Sign(math.Subtract(to.Exact, from.Exact)) <= 0) throw new ArithmeticException("Use from lower to upper with lower < upper");
            lower = FormulaNumbers.ToDouble(from.Exact); upper = FormulaNumbers.ToDouble(to.Exact);
        }
        var value = PlotSampler.Sample(formula, plot.Text, lower, upper, budget, token);
        return (new(value), "Sampled curve, not an exact graph; sheet names are constants; " + FormulaFunctions.Convention);
    }
}
