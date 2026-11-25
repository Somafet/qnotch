using System.Globalization;
using System.Text;
using Calc.Core;

namespace Calc.Documents.Export;

public enum ExportLineKind { Blank, Heading, Text, Result, Error }

/// <summary>One logical source line and what the sheet shows beside it. <see cref="Result"/> is the visible text;
/// <see cref="Value"/> is the complete copy text (full digits, complete lists) when it differs or spans lines.</summary>
public sealed record ExportLine(int Number, string Source, ExportLineKind Kind, string Result, string? Value, bool IsTotal)
{
    /// <summary>Plot or chart retained for renderers that can draw it; text formats keep its textual result.</summary>
    public SheetValue? Figure { get; init; }
    public bool IsTableRow => Source.Contains('\t');
}

/// <summary>Immutable, bounded snapshot of a sheet's source and results. Every export, copy and image consumes the same rows,
/// so text, Markdown, CSV, PDF, print and PNG agree on content. No evaluation happens here.</summary>
public sealed class SheetExport
{
    /// <summary>Upper bound on any serialized export, in UTF-16 characters. A full sheet with complete copy values stays well inside it.</summary>
    public const int MaxOutputCharacters = 8_000_000;
    public string Title { get; }
    public IReadOnlyList<ExportLine> Lines { get; }

    private SheetExport(string title, IReadOnlyList<ExportLine> lines) { Title = title; Lines = lines; }

    /// <summary>Builds the snapshot. Results are matched by line index; lines without a matching result export as source only.
    /// Results read as the sheet shows them: the number style/decimals in <paramref name="format"/> and any default-currency
    /// conversion (<see cref="LineResult.Shown"/>), so every export matches the gutter and click-copy.</summary>
    public static SheetExport Create(string title, string source, IReadOnlyList<LineResult> results, ResultFormat? format = null)
    {
        format ??= ResultFormat.Default;
        ArgumentNullException.ThrowIfNull(source); ArgumentNullException.ThrowIfNull(results);
        if (source.Length > SheetStore.MaxCharacters) throw new ArgumentException("Sheet exceeds the export limit");
        var map = new SourceLineMap(source);
        if (map.Count > SheetEvaluator.MaxLines) throw new ArgumentException("Sheet exceeds the export line limit");
        var lines = new ExportLine[map.Count];
        for (var i = 0; i < map.Count; i++)
        {
            var text = source[map.Start(i)..map.ContentEnd(i)];
            var answer = i < results.Count && results[i].Line == i ? results[i] : null;
            var trimmed = text.Trim();
            ExportLineKind kind; string shown = ""; string? value = null; SheetValue? figure = null;
            if (trimmed.Length == 0) kind = ExportLineKind.Blank;
            else if (trimmed == "#" || trimmed.StartsWith("# ", StringComparison.Ordinal)) kind = ExportLineKind.Heading;
            else if (answer is { Error: { } error }) { kind = ExportLineKind.Error; shown = OneLine(error); }
            else if (answer is { Value: { } result } && answer.Display.Length > 0)
            {
                kind = ExportLineKind.Result; shown = OneLine(ResultFormatter.Format(answer, format));
                var copy = (answer.Shown ?? result).CopyText;
                if (copy != shown) value = copy;
                if (result.Kind is SheetValueKind.Plot or SheetValueKind.Chart) figure = result;
            }
            else kind = ExportLineKind.Text;
            lines[i] = new(i + 1, text, kind, shown, value, kind == ExportLineKind.Result && answer!.IsAggregate) { Figure = figure };
        }
        return new(title.Trim().Length == 0 ? "Sheet" : title.Trim(), Array.AsReadOnly(lines));
    }

    private static string OneLine(string text) => text.Contains('\n') || text.Contains('\r') ? string.Join(' ', text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)) : text;

    /// <summary>The last `sum`/`average` line, which is the sheet's own total. Null when the sheet declares none.</summary>
    public ExportLine? Total => Lines.LastOrDefault(line => line.IsTotal);
    public string? TotalText => Total is { } total ? total.Value ?? total.Result : null;
    public bool HasResults => Lines.Any(line => line.Kind == ExportLineKind.Result);

    /// <summary>Results only, one row per source line so a paste lines up with the source; errors and prose leave empty rows.
    /// Single-line complete values replace abbreviated displays.</summary>
    public string ResultsText()
    {
        var rows = Lines.Select(line => line.Kind != ExportLineKind.Result ? "" : line.Value is { } value && !value.Contains('\n') && !value.Contains('\r') ? value : line.Result).ToList();
        while (rows.Count > 0 && rows[^1].Length == 0) rows.RemoveAt(rows.Count - 1);
        return Bounded(string.Join("\r\n", rows));
    }

    /// <summary>Source and visible result columns. Results right-align in one column; a long source pushes only its own result.</summary>
    public string PlainText()
    {
        const int MaxSourceColumn = 56;
        var calculated = Lines.Where(line => line.Kind is ExportLineKind.Result or ExportLineKind.Error && !line.IsTableRow).ToArray();
        var sourceColumn = Math.Min(MaxSourceColumn, calculated.Select(line => DisplayWidth(line.Source.TrimEnd())).DefaultIfEmpty(0).Max());
        var resultColumn = calculated.Select(line => DisplayWidth(line.Result)).DefaultIfEmpty(0).Max();
        var text = new StringBuilder();
        foreach (var line in Lines)
        {
            var source = line.Source.TrimEnd();
            if (line.Kind is ExportLineKind.Result or ExportLineKind.Error && line.Result.Length > 0)
            {
                var width = DisplayWidth(source);
                text.Append(source);
                if (line.IsTableRow) text.Append('\t').Append(line.Result);
                else text.Append(' ', Math.Max(2, sourceColumn - width + 2)).Append(' ', Math.Max(0, resultColumn - DisplayWidth(line.Result))).Append(line.Result);
            }
            else text.Append(source);
            text.Append("\r\n");
            Guard(text);
        }
        return text.ToString();
    }

    /// <summary>GitHub-flavoured Markdown. Headings stay headings; each calculation block becomes a two-column table (empty header cells,
    /// results right-aligned); a block of tab-separated worksheet rows becomes its own table; prose stays prose.</summary>
    public string Markdown()
    {
        var text = new StringBuilder(); var block = new List<ExportLine>();
        void Separate() { if (text.Length > 0) text.Append("\r\n"); }
        void Flush()
        {
            if (block.Count == 0) return;
            Separate();
            if (block.All(line => line.IsTableRow))
            {
                var cells = block.Select(line => line.Source.Split('\t').Select(cell => Escape(cell.Trim())).ToList()).ToList();
                var columns = cells.Max(row => row.Count);
                foreach (var row in cells) while (row.Count < columns) row.Add("");
                text.Append("| ").Append(string.Join(" | ", cells[0])).Append(" |\r\n|").Append(string.Concat(Enumerable.Repeat(" --- |", columns))).Append("\r\n");
                foreach (var row in cells.Skip(1)) text.Append("| ").Append(string.Join(" | ", row)).Append(" |\r\n");
            }
            else if (block.Any(line => line.Kind is ExportLineKind.Result or ExportLineKind.Error))
            {
                text.Append("| | |\r\n| --- | ---: |\r\n");
                foreach (var line in block)
                {
                    var result = line.Kind == ExportLineKind.Error ? "*" + Escape(line.Result) + "*" : line.IsTotal ? "**" + Escape(line.Result) + "**" : Escape(line.Result);
                    text.Append("| ").Append(Escape(line.Source.Replace('\t', ' ').Trim())).Append(" | ").Append(result).Append(" |\r\n");
                }
            }
            else text.Append(string.Join("  \r\n", block.Select(line => EscapeProse(line.Source.Trim())))).Append("\r\n");
            block.Clear(); Guard(text);
        }
        foreach (var line in Lines)
        {
            if (line.Kind == ExportLineKind.Blank) { Flush(); continue; }
            if (line.Kind == ExportLineKind.Heading)
            {
                Flush();
                var heading = line.Source.Trim().TrimStart('#').Trim();
                if (heading.Length > 0) { Separate(); text.Append("# ").Append(EscapeProse(heading)).Append("\r\n"); }
                continue;
            }
            if (block.Count > 0 && block[^1].IsTableRow != line.IsTableRow) Flush();
            block.Add(line);
        }
        Flush();
        return text.ToString();
    }

    /// <summary>RFC 4180 CSV with a header row. Result is the visible text; Value holds the complete copy when it differs.
    /// Cells that a spreadsheet would execute as a formula are prefixed with an apostrophe; plain signed numbers are left intact.</summary>
    public string Csv()
    {
        var text = new StringBuilder("Line,Source,Result,Value,Error\r\n");
        foreach (var line in Lines)
        {
            if (line.Kind == ExportLineKind.Blank) continue;
            var result = line.Kind == ExportLineKind.Result ? line.Result : "";
            var value = line.Kind == ExportLineKind.Result ? line.Value ?? line.Result : "";
            var error = line.Kind == ExportLineKind.Error ? line.Result : "";
            text.Append(line.Number.ToString(CultureInfo.InvariantCulture)).Append(',').Append(CsvCell(line.Source)).Append(',')
                .Append(CsvCell(result)).Append(',').Append(CsvCell(value)).Append(',').Append(CsvCell(error)).Append("\r\n");
            Guard(text);
        }
        return text.ToString();
    }

    /// <summary>Rows for a pasted table: worksheet tab cells stay cells and the visible result is the last cell. Blank lines are omitted.</summary>
    public IReadOnlyList<IReadOnlyList<string>> TableRows() => Lines.Where(line => line.Kind != ExportLineKind.Blank)
        .Select(line => (IReadOnlyList<string>)[.. line.Source.Split('\t').Select(cell => cell.Trim()), .. line.Result.Length > 0 && line.Kind == ExportLineKind.Result ? [line.Result] : Array.Empty<string>()])
        .ToArray();

    public string TableTsv() => Bounded(string.Join("\r\n", TableRows().Select(row => string.Join('\t', row.Select(cell => cell.Replace('\t', ' '))))));

    public string TableHtml()
    {
        var html = new StringBuilder("<table>");
        foreach (var row in TableRows())
        {
            html.Append("<tr>");
            foreach (var cell in row) html.Append("<td>").Append(System.Net.WebUtility.HtmlEncode(cell)).Append("</td>");
            html.Append("</tr>"); Guard(html);
        }
        return html.Append("</table>").ToString();
    }

    internal static string CsvCell(string cell)
    {
        if (cell.Length > 0 && (cell[0] is '=' or '+' or '@' or '\t' or '\r' || cell[0] == '-' && !IsPlainNumber(cell))) cell = "'" + cell;
        return cell.IndexOfAny([',', '"', '\r', '\n']) >= 0 ? "\"" + cell.Replace("\"", "\"\"") + "\"" : cell;
    }
    private static bool IsPlainNumber(string cell) => decimal.TryParse(cell, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out _);

    private static string Escape(string cell)
    {
        var text = new StringBuilder(cell.Length + 8);
        foreach (var c in cell)
        {
            if (c is '\\' or '|' or '`' or '*' or '_' or '[' or ']' or '<' or '>' or '~' or '#') text.Append('\\');
            text.Append(c);
        }
        return text.ToString();
    }
    // Prose escapes the same inline marks; a leading list/quote/number marker would otherwise turn a line into structure.
    private static string EscapeProse(string line)
    {
        var escaped = Escape(line);
        if (escaped.Length > 0 && escaped[0] is '-' or '+' || escaped.Length > 1 && char.IsAsciiDigit(escaped[0]) && escaped.TakeWhile(char.IsAsciiDigit).Count() is var digits && digits < escaped.Length && escaped[digits] is '.' or ')')
        {
            var at = escaped[0] is '-' or '+' ? 0 : escaped.TakeWhile(char.IsAsciiDigit).Count();
            escaped = escaped.Insert(at, "\\");
        }
        return escaped;
    }

    /// <summary>Monospace column width: combining/format marks take none, East Asian wide and emoji take two.</summary>
    public static int DisplayWidth(string text)
    {
        var width = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark or UnicodeCategory.Format) continue;
            var v = rune.Value;
            width += v is >= 0x1100 and <= 0x115F or >= 0x2E80 and <= 0xA4CF or >= 0xAC00 and <= 0xD7A3 or >= 0xF900 and <= 0xFAFF or >= 0xFE30 and <= 0xFE4F
                or >= 0xFF00 and <= 0xFF60 or >= 0xFFE0 and <= 0xFFE6 or >= 0x1F300 and <= 0x1FAFF or >= 0x20000 and <= 0x3FFFD ? 2 : 1;
        }
        return width;
    }
    private static void Guard(StringBuilder text) { if (text.Length > MaxOutputCharacters) throw new ArgumentException("Export exceeds the output limit"); }
    private static string Bounded(string text) => text.Length > MaxOutputCharacters ? throw new ArgumentException("Export exceeds the output limit") : text;
}
