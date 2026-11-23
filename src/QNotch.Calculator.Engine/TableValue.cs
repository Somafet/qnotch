using System.Globalization;

namespace Calc.Core;

/// <summary>One source cell: the trimmed text, and its value when the cell is a numeric, percentage, money or unit literal.</summary>
public readonly record struct TableCell(string Text, SheetValue? Value);

/// <summary>Immutable rectangular table parsed from plain source lines. Text and blank cells stay in place and numeric selections skip them.</summary>
public sealed class TableValue : IEquatable<TableValue>
{
    public const int MaxColumns = 64, MaxRows = 1024;
    private readonly TableCell[][] rows;
    private readonly int hash;
    public IReadOnlyList<string>? Header { get; }
    public int RowCount => rows.Length;
    public int ColumnCount { get; }
    /// <summary>Document lines the table occupies, header included.</summary>
    public int SourceRows => rows.Length + (Header is null ? 0 : 1);
    internal TableValue(IEnumerable<TableCell[]> data, IReadOnlyList<string>? header, int columns)
    {
        rows = data.ToArray(); Header = header is null ? null : Array.AsReadOnly(header.ToArray()); ColumnCount = columns;
        var code = new HashCode(); code.Add(columns);
        foreach (var cell in rows.SelectMany(row => row)) code.Add(cell.Value is { } value ? value.GetHashCode() : StringComparer.Ordinal.GetHashCode(cell.Text));
        foreach (var name in Header ?? []) code.Add(StringComparer.Ordinal.GetHashCode(name));
        hash = code.ToHashCode();
    }
    public TableCell this[int row, int column] => rows[row][column];
    public string Display => RowCount + "×" + ColumnCount + " table";
    public string CopyText
    {
        get
        {
            if (Header is null) return Display;
            var names = string.Join(", ", Header);
            return Display + ": " + (names.Length <= 256 ? names : names[..256] + "…");
        }
    }
    private int NumericCells => rows.Sum(row => row.Count(cell => cell.Value is not null));
    public string Summary => RowCount + " rows, " + ColumnCount + " columns" + (Header is null ? ", no header" : ", first line is the header") + "\n" + NumericCells + " numeric cells; text and blank cells are skipped";
    public string Details => Summary + "\nThe source stays plain text in the sheet. Refer to it with column(table, \"name\"), column(table, n) and row(table, n).";
    internal int ColumnIndex(string name)
    {
        if (Header is null) throw new ArithmeticException("This table has no header; use a column number");
        var matches = Enumerable.Range(0, Header.Count).Where(i => Header[i].Equals(name, StringComparison.OrdinalIgnoreCase)).ToArray();
        return matches.Length == 1 ? matches[0] : throw new ArithmeticException(matches.Length == 0 ? "Unknown column: " + name : "More than one column is named " + name + "; use a column number");
    }
    // A column made only of text labels the values of the other columns.
    private int LabelColumn(int selected)
    {
        for (var column = 0; column < ColumnCount; column++)
            if (column != selected && rows.All(row => row[column].Value is null) && rows.Any(row => row[column].Text.Length > 0)) return column;
        return -1;
    }
    private static (SheetList List, int Skipped) Select(int count, Func<int, TableCell> cell, Func<int, string> label, string empty)
    {
        var values = new List<SheetValue>(); var labels = new List<string>();
        for (var i = 0; i < count; i++)
            if (cell(i).Value is { } value) { values.Add(value); labels.Add(label(i)); }
        return values.Count == 0 ? throw new ArithmeticException(empty) : (new SheetList(values, labels), count - values.Count);
    }
    private static string Ordinal(int index) => (index + 1).ToString(CultureInfo.InvariantCulture);
    internal (SheetList List, int Skipped) Column(int index)
    {
        var labels = LabelColumn(index);
        return Select(RowCount, row => rows[row][index], row => labels >= 0 ? rows[row][labels].Text : Ordinal(row), "Column " + Ordinal(index) + " has no numeric cells");
    }
    internal (SheetList List, int Skipped) Row(int index) => Select(ColumnCount, column => rows[index][column], column => Header?[column] ?? Ordinal(column), "Row " + Ordinal(index) + " has no numeric cells");
    // Numeric cells compare by value, so reformatting 5 as 5.0 leaves dependents reusable; text cells compare by text.
    public bool Equals(TableValue? other) => ReferenceEquals(this, other) || other is not null && hash == other.hash && RowCount == other.RowCount && ColumnCount == other.ColumnCount &&
        (Header ?? []).SequenceEqual(other.Header ?? [], StringComparer.Ordinal) && rows.Zip(other.rows).All(pair => pair.First.Zip(pair.Second).All(cells => cells.First.Value == cells.Second.Value && (cells.First.Value is not null || cells.First.Text == cells.Second.Text)));
    public override bool Equals(object? obj) => obj is TableValue other && Equals(other);
    public override int GetHashCode() => hash;
    public override string ToString() => Display;
}
