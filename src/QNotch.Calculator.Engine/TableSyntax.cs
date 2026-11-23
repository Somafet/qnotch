using System.Text;
using System.Text.RegularExpressions;

namespace Calc.Core;

internal sealed record TableExpression(TableValue Value) : Expression;
internal sealed record TableBlock(int First, int Start, int Rows, int Columns, string Name, bool Automatic);

/// <summary>Where the tables are in one source snapshot. A table's cache key covers its whole block, so a cell edit re-parses that table and nothing else.</summary>
internal sealed class TableLayout
{
    private static readonly ParsedLine Quiet = new("", null, [], false, null, null);
    private readonly TableBlock?[]? owners;
    internal IReadOnlyList<TableBlock> Blocks { get; }
    internal string[] Keys { get; }
    internal TableLayout(string[] lines, IReadOnlyList<TableBlock> blocks)
    {
        Blocks = blocks; Keys = lines;
        if (blocks.Count == 0) return;
        owners = new TableBlock?[lines.Length]; Keys = lines.ToArray();
        foreach (var block in blocks)
        {
            // Source lines never contain a newline, so these keys cannot match ordinary text.
            for (var i = block.First; i < block.Start + block.Rows; i++) { owners[i] = block; Keys[i] = "\n"; }
            Keys[block.Start] = "\n" + block.Name + "\n" + string.Join('\n', lines, block.Start, block.Rows);
        }
    }
    internal bool Owns(int line) => owners?[line] is not null;
    internal ParsedLine? Scan(int line, string[] lines, CancellationToken token)
    {
        if (owners?[line] is not { } block) return null;
        if (line != block.Start) return Quiet;
        if (block.Columns > TableValue.MaxColumns) return Quiet with { Error = "Table exceeds 64 columns" };
        var rows = new TableCell[block.Rows][];
        for (var i = 0; i < rows.Length; i++)
        {
            token.ThrowIfCancellationRequested();
            rows[i] = lines[block.Start + i].Split('\t').Select(cell => TableSyntax.Cell(cell.Trim(), token)).ToArray();
        }
        var header = rows[0].Any(cell => cell.Value is null && cell.Text.Length > 0);
        if (rows.Length - (header ? 1 : 0) > TableValue.MaxRows) return Quiet with { Error = "Table exceeds 1024 rows" };
        var table = new TableValue(rows.Skip(header ? 1 : 0), header ? rows[0].Select(cell => cell.Text).ToArray() : null, block.Columns);
        return Quiet with { Text = lines[line], Assignment = block.Name, Expression = new TableExpression(table) };
    }
}

/// <summary>Plain-text table recognition and CSV paste normalization. Pure: no clipboard, file or host access.</summary>
public static class TableSyntax
{
    private const int MaxCellCharacters = 64;
    private static readonly Regex GroupSeparator = new(@"(?<=\d),(?=\d{3}(?!\d))", RegexOptions.Compiled | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(20));
    private static int Columns(string line)
    {
        if (!line.Contains('\t')) return 0;
        var trimmed = line.TrimStart();
        return trimmed.Length == 0 || trimmed.StartsWith("# ", StringComparison.Ordinal) || trimmed.StartsWith("//", StringComparison.Ordinal) ? 0 : line.Count(c => c == '\t') + 1;
    }
    // Two filled cells on the first row keep indented lines and stray trailing tabs ordinary source.
    private static bool Opens(string line) => line.Split('\t').Count(cell => cell.Trim().Length > 0) >= 2;
    internal static TableLayout Layout(string[] lines, CancellationToken token)
    {
        var blocks = new List<TableBlock>(); var unnamed = 0;
        for (var i = 0; i < lines.Length;)
        {
            token.ThrowIfCancellationRequested();
            var columns = Columns(lines[i]); var end = i + 1;
            if (columns >= 2) while (end < lines.Length && Columns(lines[end]) == columns) end++;
            if (end - i >= 2 && Opens(lines[i]))
            {
                var label = i > 0 ? lines[i - 1].Trim() : "";
                var name = label.EndsWith(':') ? SheetSyntax.NormalizeName(label[..^1]) : "";
                var named = SheetSyntax.ValidName(name);
                if (named || !LabelList(lines, i, end, token))
                    blocks.Add(new(named ? i - 1 : i, i, end - i, columns, named ? name : "table" + ++unnamed, !named));
            }
            i = end;
        }
        return new(lines, blocks);
    }
    // Unnamed `label<TAB>amount` lines with no header evaluated as labelled numbers before tables existed; they stay ordinary lines.
    private static bool LabelList(string[] lines, int start, int end, CancellationToken token)
    {
        for (var i = start; i < end; i++)
        {
            token.ThrowIfCancellationRequested(); var cells = lines[i].Split('\t');
            if (cells.Length != 2 || cells[0].Trim() is not { Length: > 0 } label || Literal(label, token) is not null || Literal(cells[1].Trim(), token) is null) return false;
        }
        return true;
    }
    internal static TableCell Cell(string text, CancellationToken token) => new(text, Literal(text, token));
    private static SheetValue? Literal(string text, CancellationToken token)
    {
        if (text.Length is 0 or > MaxCellCharacters || !text.Any(char.IsAsciiDigit) || text.Contains('(')) return null;
        if (text.All(c => char.IsAsciiDigit(c) || c == '.') && text.Count(c => c == '.') <= 1) return new(Rational.Parse(text));
        try
        {
            var source = text.Contains(',') ? GroupSeparator.Replace(text, "") : text;
            var node = new ExpressionParser(ExpressionParser.Tokenize(source, token), token).Parse();
            if (!ExpressionEvaluation.Walk(node).All(IsLiteralNode)) return null;
            var value = ExpressionEvaluation.Evaluate(node, _ => throw new FormatException("Table cells cannot refer to names"), [], token).Value;
            return value.Kind is SheetValueKind.Number or SheetValueKind.Money ? value : null;
        }
        catch (Exception e) when (e is FormatException or ArithmeticException or RegexMatchTimeoutException) { return null; }
    }
    private static bool IsLiteralNode(Expression node) => node is LiteralExpression or ScaleExpression or CurrencyAttachExpression or UnitExpressionNode { Conversion: false } or UnaryExpression { Operation: "-" or "+" or "%" };

    /// <summary>Converts RFC 4180 CSV or semicolon separated text into TSV, or returns the same text when it is not unmistakably a table.</summary>
    public static string TryNormalizePaste(string text)
    {
        if (text.Contains('\t') || !text.AsSpan().TrimEnd("\r\n").ContainsAny('\r', '\n')) return text;
        // Semicolon first: where it separates cells, a comma is usually the decimal mark.
        foreach (var delimiter in ";,")
            if (Fields(text, delimiter, out var digitComma) is { } rows && Tabular(rows) && (!digitComma || !rows[0].Any(Numeric)) && !rows.All(LabelRow)) return string.Join('\n', rows.Select(row => string.Join('\t', row))) + (text.EndsWith('\n') || text.EndsWith('\r') ? "\n" : "");
        return text;
    }
    private static bool Tabular(List<string[]> rows)
    {
        if (rows.Count < 2 || rows.Count > TableValue.MaxRows + 1) return false;
        var columns = rows[0].Length;
        if (columns is < 2 or > TableValue.MaxColumns || rows.Any(row => row.Length != columns) || rows[0].Count(cell => cell.Length > 0) < 2) return false;
        // Expressions and prose also contain commas; a table has balanced cells and at least one number, in either decimal notation.
        return !rows.Any(row => row.Any(Code)) && rows.Any(row => row.Any(cell => Literal(cell.Replace(',', '.'), default) is not null));
    }
    // A comma between two digits may be a group separator (1,200) or a decimal mark (3,5); without a text header row it is not a field separator.
    private static bool Numeric(string cell) => Literal(cell, default) is not null;
    // Headerless label, amount rows would not form a table after conversion, so the paste keeps its own text.
    private static bool LabelRow(string[] row) => row.Length == 2 && row[0].Length > 0 && !Numeric(row[0]) && Numeric(row[1]);
    private static bool Code(string cell) => cell.Contains('=') || cell.Count(c => c == '(') != cell.Count(c => c == ')') || cell.Count(c => c == '[') != cell.Count(c => c == ']');
    private static List<string[]>? Fields(string text, char delimiter, out bool digitComma)
    {
        digitComma = false;
        var rows = new List<string[]>(); var row = new List<string>(); var field = new StringBuilder();
        bool quoted = false, closed = false, wasQuoted = false;
        void EndField() { row.Add(wasQuoted ? field.ToString() : field.ToString().Trim()); field.Clear(); closed = false; wasQuoted = false; }
        void EndRow() { EndField(); rows.Add(row.ToArray()); row.Clear(); }
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (quoted)
            {
                if (c != '"') field.Append(c is '\r' or '\n' ? ' ' : c);
                else if (i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; }
                else { quoted = false; closed = true; }
            }
            else if (c == delimiter) { digitComma |= c == ',' && i > 0 && i + 1 < text.Length && char.IsAsciiDigit(text[i - 1]) && char.IsAsciiDigit(text[i + 1]); EndField(); }
            else if (c is '\r' or '\n') { if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++; EndRow(); }
            else if (closed) { if (!char.IsWhiteSpace(c)) return null; }
            else if (c == '"') { if (field.ToString().Trim().Length > 0) return null; field.Clear(); quoted = true; wasQuoted = true; }
            else field.Append(c);
        }
        if (quoted) return null;
        if (field.Length > 0 || row.Count > 0 || wasQuoted) EndRow();
        return rows;
    }
}

/// <summary>column(table, "name" | n) and row(table, n) select one line of a table as a labelled list.</summary>
internal static class TableArithmetic
{
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "column" or "row";
    internal static (SheetValue Value, string Assumption) Function(string name, SheetValue[] args)
    {
        if (args.Length != 2) throw new FormatException(name + " expects (table, position)");
        if (args[0].Kind != SheetValueKind.Table) throw new ArithmeticException(name + " expects a table");
        var table = args[0].Table; var column = name.Equals("column", StringComparison.OrdinalIgnoreCase);
        var index = column && args[1].Kind == SheetValueKind.Text ? table.ColumnIndex(args[1].Text.Value) : Position(args[1], column ? table.ColumnCount : table.RowCount, column ? "Column" : "Row");
        var (list, skipped) = column ? table.Column(index) : table.Row(index);
        return (new(list), list.Values.Count + " numeric cells; " + skipped + " text or blank cells skipped; header excluded");
    }
    private static int Position(SheetValue value, int limit, string role)
    {
        if (value.Kind != SheetValueKind.Number || value.Number.Unit is not null || !value.Number.IsRational || value.Number.IsPercentage) throw new ArithmeticException(role + " must be a whole number or a header name");
        var position = value.Number.Scalar;
        if (position.Denominator != 1 || position.Numerator < 1 || position.Numerator > limit) throw new ArithmeticException(role + " must be a whole number from 1 to " + limit);
        return (int)position.Numerator - 1;
    }
}
