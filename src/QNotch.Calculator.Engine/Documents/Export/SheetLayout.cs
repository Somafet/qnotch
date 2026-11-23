using System.Globalization;
using Calc.Core;

namespace Calc.Documents.Export;

public enum LayoutStyle { Source, Heading, Result, Total, Error }

/// <summary>Geometry in caller units (DIPs for images and print, points for PDF). A continuous layout has an infinite page height and stops at <see cref="MaxHeight"/>.</summary>
public sealed record LayoutOptions(double Width, double PageHeight, double Margin, double LineHeight)
{
    public double FigureHeight { get; init; } = 120;
    public double FigureGap { get; init; } = 10;
    public double ColumnGap { get; init; } = 24;
    /// <summary>Continuous layouts only: rows past this height are omitted and counted.</summary>
    public double MaxHeight { get; init; } = 12_000;
    public int MaxPages { get; init; } = 2_000;
    public bool Continuous => double.IsPositiveInfinity(PageHeight);
}

public sealed record LayoutRun(double X, double Top, string Text, LayoutStyle Style, int Line);
public sealed record LayoutFigure(double X, double Top, double Width, double Height, int Line, SheetValue Value);
public sealed record LayoutPage(int Number, IReadOnlyList<LayoutRun> Runs, IReadOnlyList<LayoutFigure> Figures, double Height);
public sealed record SheetLayout(IReadOnlyList<LayoutPage> Pages, double Width, LayoutOptions Options, int OmittedLines);

/// <summary>Places an export's rows the way the sheet reads: source on the left, results right-aligned in one column, worksheet cells on column stops,
/// figures under their line. Text measurement is supplied by the renderer so positions match its font exactly. Widths are additive per word,
/// which keeps very long lines linear in their length.</summary>
public static class SheetLayoutComposer
{
    private sealed record Row(List<LayoutRun> Runs, double Height, LayoutFigure? Figure = null);

    public static SheetLayout Compose(SheetExport export, LayoutOptions options, Func<string, LayoutStyle, double> measure)
    {
        ArgumentNullException.ThrowIfNull(export); ArgumentNullException.ThrowIfNull(measure);
        if (!(options.Width > options.Margin * 2 + 40) || !(options.LineHeight > 0) || !(options.PageHeight > options.Margin * 2 + options.LineHeight) && !options.Continuous)
            throw new ArgumentException("Invalid export geometry");
        var content = options.Width - options.Margin * 2;
        var left = options.Margin; var right = options.Margin + content;
        double Measure(string text, LayoutStyle style) => text.Length == 0 ? 0 : Math.Max(0, measure(text, style));
        var calculated = export.Lines.Where(line => line.Kind is ExportLineKind.Result or ExportLineKind.Error).ToArray();
        var resultColumn = Math.Min(content * 0.45, calculated.Select(line => Measure(line.Result, Style(line))).DefaultIfEmpty(0).Max());
        var sourceWidth = resultColumn > 0 ? content - resultColumn - options.ColumnGap : content;
        var stops = TableStops(export, measure, options.ColumnGap, sourceWidth);

        var pages = new List<LayoutPage>(); var runs = new List<LayoutRun>(); var figures = new List<LayoutFigure>();
        var top = options.Margin; var omitted = 0;
        var bottom = options.Continuous ? options.MaxHeight - options.Margin : options.PageHeight - options.Margin;
        void NewPage()
        {
            pages.Add(new(pages.Count + 1, runs.ToArray(), figures.ToArray(), options.Continuous ? top + options.Margin : options.PageHeight));
            if (pages.Count >= options.MaxPages) throw new ArgumentException("Export exceeds the page limit");
            runs = []; figures = []; top = options.Margin;
        }
        void Place(Row row)
        {
            foreach (var run in row.Runs) runs.Add(run with { Top = top + run.Top });
            if (row.Figure is { } figure) figures.Add(figure with { Top = top + figure.Top });
            top += row.Height;
        }
        for (var index = 0; index < export.Lines.Count; index++)
        {
            var line = export.Lines[index];
            var rows = Rows(line, stops.GetValueOrDefault(index), options, content, sourceWidth, resultColumn, left, right, Measure);
            var height = rows.Sum(row => row.Height);
            if (options.Continuous)
            {
                if (top + height > bottom && top > options.Margin) { omitted = export.Lines.Count - index; break; }
                rows.ForEach(Place); continue;
            }
            if (top + height > bottom && top > options.Margin && height <= bottom - options.Margin) NewPage();
            foreach (var row in rows)
            {
                if (top + row.Height > bottom && top > options.Margin) NewPage();
                Place(row);
            }
        }
        pages.Add(new(pages.Count + 1, runs.ToArray(), figures.ToArray(), options.Continuous ? top + options.Margin : options.PageHeight));
        return new(pages.AsReadOnly(), options.Width, options, omitted);
    }

    private static LayoutStyle Style(ExportLine line) => line.Kind == ExportLineKind.Error ? LayoutStyle.Error : line.IsTotal ? LayoutStyle.Total : LayoutStyle.Result;

    private static List<Row> Rows(ExportLine line, double[]? stops, LayoutOptions options, double content, double sourceWidth, double resultColumn,
        double left, double right, Func<string, LayoutStyle, double> measure)
    {
        var rows = new List<Row>(); var lineHeight = options.LineHeight;
        switch (line.Kind)
        {
            case ExportLineKind.Blank: rows.Add(new([], lineHeight)); break;
            case ExportLineKind.Heading:
            case ExportLineKind.Text when stops is null:
                var style = line.Kind == ExportLineKind.Heading ? LayoutStyle.Heading : LayoutStyle.Source;
                foreach (var text in Wrap(line.Source.Replace('\t', ' '), content, style, measure)) rows.Add(new([new(left, 0, text, style, line.Number)], lineHeight));
                break;
            default:
                List<LayoutRun> sourceRuns;
                if (stops is not null)
                {
                    sourceRuns = [];
                    var cells = line.Source.Split('\t');
                    for (var i = 0; i < cells.Length; i++) if (cells[i].Trim().Length > 0) sourceRuns.Add(new(left + stops[i], 0, cells[i].Trim(), LayoutStyle.Source, line.Number));
                }
                else sourceRuns = [.. Wrap(line.Source.Replace('\t', ' '), sourceWidth, LayoutStyle.Source, measure).Select((text, i) => new LayoutRun(left, i * lineHeight, text, LayoutStyle.Source, line.Number))];
                var resultStyle = Style(line);
                var results = line.Result.Length == 0 ? [] : Wrap(line.Result, Math.Max(resultColumn, 1), resultStyle, measure)
                    .Select((text, i) => new LayoutRun(right - measure(text, resultStyle), i * lineHeight, text, resultStyle, line.Number)).ToList<LayoutRun>();
                var count = Math.Max(1, Math.Max(stops is not null ? 1 : sourceRuns.Count, results.Count));
                for (var i = 0; i < count; i++)
                {
                    var rowRuns = sourceRuns.Where(run => stops is not null ? i == 0 : run.Top == i * lineHeight).Concat(results.Where(run => run.Top == i * lineHeight)).Select(run => run with { Top = 0 }).ToList();
                    rows.Add(new(rowRuns, lineHeight));
                }
                if (line.Figure is { } figure)
                    rows.Add(new([], options.FigureHeight + options.FigureGap, new LayoutFigure(left, 0, content, options.FigureHeight, line.Number, figure)));
                break;
        }
        return rows;
    }

    /// <summary>Column stops for each run of consecutive tab-separated rows, measured from their own cells. A run too wide for the source column wraps as text instead.</summary>
    private static Dictionary<int, double[]> TableStops(SheetExport export, Func<string, LayoutStyle, double> measure, double gap, double width)
    {
        var stops = new Dictionary<int, double[]>();
        for (var start = 0; start < export.Lines.Count;)
        {
            if (!export.Lines[start].IsTableRow || export.Lines[start].Kind is ExportLineKind.Heading) { start++; continue; }
            var end = start;
            while (end < export.Lines.Count && export.Lines[end].IsTableRow && export.Lines[end].Kind is not ExportLineKind.Heading) end++;
            var widths = new List<double>();
            for (var i = start; i < end; i++)
            {
                var cells = export.Lines[i].Source.Split('\t');
                for (var c = 0; c < cells.Length; c++)
                {
                    var w = cells[c].Trim().Length == 0 ? 0 : measure(cells[c].Trim(), LayoutStyle.Source);
                    if (c == widths.Count) widths.Add(w); else widths[c] = Math.Max(widths[c], w);
                }
            }
            var positions = new double[widths.Count]; var x = 0d;
            for (var c = 0; c < widths.Count; c++) { positions[c] = x; x += widths[c] + gap; }
            if (x - gap <= width) for (var i = start; i < end; i++) stops[i] = positions;
            start = end;
        }
        return stops;
    }

    /// <summary>Greedy word wrap that keeps leading indentation. Words wider than the line break between text elements, never inside a surrogate pair or combining sequence.</summary>
    public static IReadOnlyList<string> Wrap(string text, double width, LayoutStyle style, Func<string, LayoutStyle, double> measure)
    {
        if (text.Length == 0) return [""];
        var lines = new List<string>(); var current = new System.Text.StringBuilder(); var used = 0d; var content = false;
        void Push() { lines.Add(current.ToString().TrimEnd()); current.Clear(); used = 0; content = false; }
        void Append(string part, double w) { current.Append(part); used += w; content |= part.Trim().Length > 0; }
        foreach (var whole in Tokens(text))
        {
            var token = whole; var w = measure(token, style);
            if (used + w <= width) { Append(token, w); continue; }
            if (content)
            {
                Push(); token = token.TrimStart(); w = measure(token, style);
                if (w <= width) { Append(token, w); continue; }
            }
            var elements = StringInfo.GetTextElementEnumerator(token);
            while (elements.MoveNext())
            {
                var element = (string)elements.Current; var ew = measure(element, style);
                if (used + ew > width && content) { Push(); if (element.Trim().Length == 0) continue; }
                Append(element, ew);
            }
        }
        if (current.Length > 0 || lines.Count == 0) Push();
        return lines;
    }

    // Each token is a word with the spaces before it, so indentation stays attached to the first word.
    private static IEnumerable<string> Tokens(string text)
    {
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] != ' ' || i == start || text[i - 1] == ' ') continue;
            yield return text[start..i]; start = i;
        }
        if (start < text.Length) yield return text[start..];
    }
}
