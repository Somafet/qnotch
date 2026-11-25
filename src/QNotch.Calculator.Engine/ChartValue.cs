using System.Globalization;

namespace Calc.Core;

public enum ChartKind { Bar, Pie, Trend }
public sealed record ChartItem(string Label, double Magnitude, string Display);

/// <summary>Immutable chart data: labelled magnitudes in one unit or currency, with the source's own formatted values.</summary>
public sealed class ChartValue : IEquatable<ChartValue>
{
    public const int MaxBars = 64, MaxTrendPoints = 512, MaxLabel = 32;
    private readonly ChartItem[] items; private readonly int hash;
    public ChartKind Kind { get; }
    public IReadOnlyList<ChartItem> Items { get; }
    public string Total { get; }
    public bool IsApproximate { get; }
    internal ChartValue(ChartKind kind, ChartItem[] data, string total, bool approximate)
    {
        Kind = kind; items = data; Items = Array.AsReadOnly(items); Total = total; IsApproximate = approximate;
        var code = new HashCode(); code.Add(kind); code.Add(StringComparer.Ordinal.GetHashCode(total));
        foreach (var item in items) code.Add(item);
        hash = code.ToHashCode();
    }
    private string Word => Kind switch { ChartKind.Bar => "Bar chart", ChartKind.Pie => "Pie chart", _ => "Trend chart" };
    private ChartItem Lowest => items.MinBy(item => item.Magnitude)!;
    private ChartItem Highest => items.MaxBy(item => item.Magnitude)!;
    public string Display => Kind == ChartKind.Trend ? items.Length + " points" : Total;
    public string CopyText => Kind == ChartKind.Trend ? "[" + string.Join(", ", items.Select(item => item.Display)) + "]" : string.Join(", ", items.Select(item => item.Label + ": " + item.Display));
    public string Summary => Word + " of " + items.Length + " values" + (Kind == ChartKind.Trend ? " in source order, evenly spaced" : ", total " + Total) + "\nFrom " + Lowest.Display + " to " + Highest.Display;
    public string Details => Summary + "\n" + string.Join('\n', items.Take(16).Select(item => item.Label + ": " + item.Display)) + (items.Length > 16 ? "\n… " + (items.Length - 16) + " more" : "") +
        "\nValues keep the first entry's unit or currency; nothing is extrapolated";
    public string Description => Word + " of " + items.Length + " values, from " + Lowest.Label + " " + Lowest.Display + " to " + Highest.Label + " " + Highest.Display;
    public bool Equals(ChartValue? other) => ReferenceEquals(this, other) || other is not null && hash == other.hash && Kind == other.Kind && Total == other.Total && items.AsSpan().SequenceEqual(other.items);
    public override bool Equals(object? obj) => obj is ChartValue other && Equals(other);
    public override int GetHashCode() => hash;
    public override string ToString() => Display;
}

internal sealed class ChartArithmetic(ExactArithmetic math, ExecutionBudget budget, CancellationToken token, MoneyArithmetic money)
{
    private static string Bounded(string text) => text.Length <= ChartValue.MaxLabel ? text : text[..(ChartValue.MaxLabel - 1)] + "…";
    internal (SheetValue Value, string Assumption) Build(ChartKind kind, SheetValue? data, IReadOnlyList<SheetValue> lines, IReadOnlyList<string>? lineLabels)
    {
        SheetValue[] values; string[] labels;
        if (data is { } argument)
        {
            if (argument.Kind != SheetValueKind.List) throw new ArithmeticException("A chart needs a list, a named list or a table column");
            values = argument.List.Values.ToArray();
            labels = argument.List.Labels?.ToArray() ?? Enumerable.Range(1, values.Length).Select(i => i.ToString(CultureInfo.InvariantCulture)).ToArray();
        }
        else
        {
            var kept = Enumerable.Range(0, lines.Count).Where(i => !ExpressionEvaluation.ExcludedFromAggregate(lines[i])).ToArray();
            values = kept.Select(i => lines[i]).ToArray(); labels = kept.Select(i => lineLabels?[i] ?? "").ToArray();
        }
        var trend = kind == ChartKind.Trend; var limit = trend ? ChartValue.MaxTrendPoints : ChartValue.MaxBars;
        if (values.Length == 0) throw new ArithmeticException(data is null ? "No preceding lines to chart in this block" : "A chart needs at least one value");
        if (values.Length > limit) throw new ArithmeticException((trend ? "A trend chart shows at most " : "A chart shows at most ") + limit + " values");
        if (trend && values.Length < 2) throw new ArithmeticException("A trend chart needs at least two values");
        if (values.Any(value => value.Kind is not SheetValueKind.Number and not SheetValueKind.Money)) throw new ArithmeticException("Charts require numeric or monetary values");
        var list = new SheetList(values);
        // Statistics owns unit, percentage, quantity-kind and currency compatibility, so a chart refuses exactly what sum refuses.
        var total = new StatisticsArithmetic(math, budget, token, money).Function(trend ? "max" : "sum", [new(list)]);
        var quantities = new QuantityArithmetic(math); var items = new ChartItem[values.Length];
        for (var i = 0; i < values.Length; i++)
        {
            budget.Step(token);
            ExactNumber exact; string display;
            if (values[0].Kind == SheetValueKind.Money)
            { var converted = money.Convert(values[i].Money, values[0].Money.Currency); exact = converted.Magnitude.Exact; display = converted.Display; }
            else
            {
                var converted = values[0].Unit is { } unit ? quantities.Convert(values[i].Number, unit) : values[i].Number;
                exact = quantities.DisplayMagnitude(converted); display = converted.Display;
            }
            if (kind == ChartKind.Pie && math.Sign(exact) < 0) throw new ArithmeticException("A pie chart cannot show negative values");
            var magnitude = FormulaNumbers.ToDouble(exact);
            if (!double.IsFinite(magnitude)) throw new ArithmeticException("Chart value is too large to draw");
            items[i] = new(Bounded(labels[i]), magnitude, Bounded(display));
        }
        if (kind == ChartKind.Pie && items.All(item => item.Magnitude == 0)) throw new ArithmeticException("A pie chart needs a nonzero total");
        var value = new ChartValue(kind, items, total.Value.Display, list.IsApproximate);
        return (new(value), value.Summary.Replace("\n", "; ") + (money.Provenance is { } source ? "; " + source : ""));
    }
}
