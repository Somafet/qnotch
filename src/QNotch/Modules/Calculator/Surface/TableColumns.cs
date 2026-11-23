using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.TextFormatting;
using Calc.Core;
using ICSharpCode.AvalonEdit.Document;
using ICSharpCode.AvalonEdit.Rendering;

namespace Calc.Windows;

/// <summary>Draws a table's tabs as column gaps sized from its own cells. The tab stays one character in the document; only its width changes.</summary>
internal sealed class TableColumns : VisualLineElementGenerator
{
    private const int MeasuredRows = 128;
    private const double ColumnGap = 24, MinimumGap = 12;
    private sealed record Layout(TableValue Table, double[] Stops);
    private readonly SheetEditor editor;
    private Dictionary<DocumentLine, Layout> rows = [];
    private sealed class Gap(double width) : VisualLineElement(1, 1)
    {
        public override TextRun CreateTextRun(int startVisualColumn, ITextRunConstructionContext context)
            => new InlineSpace(width, context.TextView.DefaultLineHeight, context.TextView.DefaultBaseline, LineBreakCondition.BreakPossible, TextRunProperties);
    }
    internal bool LaysOut(int lineNumber) => rows.ContainsKey(editor.Document.GetLineByNumber(lineNumber));
    internal TableColumns(SheetEditor owner) { editor = owner; owner.TextArea.TextView.ElementGenerators.Add(this); }
    private double Measure(string text) => text.Length == 0 ? 0 : new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
        new Typeface(editor.FontFamily, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal), editor.FontSize, Brushes.Black, VisualTreeHelper.GetDpi(editor).PixelsPerDip).WidthIncludingTrailingWhitespace;
    internal void Update(IReadOnlyList<LineResult> answers)
    {
        var document = editor.Document; var view = editor.TextArea.TextView; var next = new Dictionary<DocumentLine, Layout>();
        if (answers.Count == document.LineCount)
            for (var i = 0; i < answers.Count; i++)
            {
                if (answers[i].Value is not { Kind: SheetValueKind.Table } value || i + value.Table.SourceRows > document.LineCount || !IsSource(i, value.Table)) continue;
                var first = document.GetLineByNumber(i + 1);
                var layout = rows.TryGetValue(first, out var known) && ReferenceEquals(known.Table, value.Table) ? known : new Layout(value.Table, Stops(i, value.Table));
                for (var row = 0; row < value.Table.SourceRows; row++) next[document.GetLineByNumber(i + 1 + row)] = layout;
            }
        var changed = rows.Where(pair => !next.TryGetValue(pair.Key, out var layout) || !layout.Stops.AsSpan().SequenceEqual(pair.Value.Stops)).Select(pair => pair.Key)
            .Concat(next.Keys.Where(line => !rows.ContainsKey(line))).ToArray();
        rows = next;
        foreach (var line in changed) if (!line.IsDeleted) view.Redraw(line);
    }
    // An alias such as `copy = table1` also answers with the table; only the block whose every row has the table's cell count is laid out.
    private bool IsSource(int start, TableValue table)
    {
        for (var row = 0; row < table.SourceRows; row++)
        {
            var line = editor.Document.GetLineByNumber(start + 1 + row);
            var tabs = 0; for (var offset = line.Offset; offset < line.EndOffset; offset++) if (editor.Document.GetCharAt(offset) == '\t') tabs++;
            if (tabs != table.ColumnCount - 1) return false;
        }
        return true;
    }
    private double[] Stops(int start, TableValue table)
    {
        var widths = new double[table.ColumnCount];
        for (var row = 0; row < Math.Min(table.SourceRows, MeasuredRows); row++)
        {
            var cells = editor.Document.GetText(editor.Document.GetLineByNumber(start + 1 + row)).Split('\t');
            for (var column = 0; column < Math.Min(cells.Length, widths.Length); column++) widths[column] = Math.Max(widths[column], Measure(cells[column]));
        }
        var stops = new double[widths.Length];
        for (var column = 1; column < stops.Length; column++) stops[column] = stops[column - 1] + widths[column - 1] + ColumnGap;
        return stops;
    }
    public override int GetFirstInterestedOffset(int startOffset)
    {
        var line = CurrentContext.VisualLine.FirstDocumentLine;
        return rows.ContainsKey(line) && startOffset < line.EndOffset ? CurrentContext.Document.IndexOf('\t', startOffset, line.EndOffset - startOffset) : -1;
    }
    public override VisualLineElement? ConstructElement(int offset)
    {
        var document = CurrentContext.Document; var line = document.GetLineByOffset(offset);
        if (!rows.TryGetValue(line, out var layout)) return null;
        var column = 0; var start = line.Offset;
        for (var i = line.Offset; i < offset; i++) if (document.GetCharAt(i) == '\t') { column++; start = i + 1; }
        if (column + 1 >= layout.Stops.Length) return null;
        return new Gap(Math.Max(layout.Stops[column + 1] - layout.Stops[column] - Measure(document.GetText(start, offset - start)), MinimumGap));
    }
}
