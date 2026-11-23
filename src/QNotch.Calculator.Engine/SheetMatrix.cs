using System.Text;

namespace Calc.Core;

/// <summary>Immutable rectangular real matrix. A flat list remains a vector/statistical sample.</summary>
public sealed class SheetMatrix : IEquatable<SheetMatrix>
{
    public const int MaxDimension = 12;
    private readonly SheetList[] rows;
    private readonly int hash;
    public IReadOnlyList<SheetList> Rows { get; }
    public int RowCount => rows.Length;
    public int ColumnCount { get; }
    public bool IsApproximate { get; }
    public NumericValue this[int row, int column] => rows[row].Values[column].Number;

    public SheetMatrix(IEnumerable<SheetList> source)
    {
        var copy = new List<SheetList>();
        NumericValue? first = null; string kind = ""; var hashCode = new HashCode();
        foreach (var row in source)
        {
            if (copy.Count == MaxDimension) throw new ArithmeticException("Matrix exceeds 12 rows");
            if (row is null || row.Values.Count is < 1 or > MaxDimension) throw new ArithmeticException("Matrix requires 1–12 columns");
            if (copy.Count == 0) ColumnCount = row.Values.Count;
            else if (row.Values.Count != ColumnCount) throw new ArithmeticException("Matrix rows must have equal lengths");
            foreach (var value in row.Values)
            {
                if (value.Kind != SheetValueKind.Number) throw new ArithmeticException("Matrices require real numeric quantities, not money or dates");
                ValidateEntry(value.Number, first); first ??= value.Number;
                if (kind.Length > 0 && value.Number.QuantityKind.Length > 0 && kind != value.Number.QuantityKind) throw new ArithmeticException("Matrix contains incompatible quantity kinds");
                if (kind.Length == 0) kind = value.Number.QuantityKind;
            }
            copy.Add(row); hashCode.Add(row); IsApproximate |= row.IsApproximate;
        }
        if (copy.Count == 0) throw new ArithmeticException("Matrix requires at least one row");
        rows = copy.ToArray(); Rows = Array.AsReadOnly(rows); hash = hashCode.ToHashCode();
    }

    internal static void ValidateEntry(NumericValue value, NumericValue? first)
    {
        if (value.IsPercentage || value.Unit?.IsTemperaturePoint == true)
            throw new ArithmeticException("Linear algebra requires real linear quantities; use ratios or temperature differences");
        if (first is { } other && (value.Unit?.Dimension != other.Unit?.Dimension ||
            value.QuantityKind.Length > 0 && other.QuantityKind.Length > 0 && value.QuantityKind != other.QuantityKind))
            throw new ArithmeticException("Matrix/vector entries require compatible dimensions and quantity kinds");
    }

    public string Display
    {
        get
        {
            var text = new StringBuilder("["); var shown = 0;
            foreach (var row in rows)
            {
                var next = row.Display;
                if (text.Length + next.Length > 512) break;
                if (shown++ > 0) text.Append(", ");
                text.Append(next);
            }
            if (shown < rows.Length) text.Append(shown > 0 ? ", …" : "…");
            return text.Append(']').ToString();
        }
    }
    public string CopyText => "[" + string.Join(", ", rows.Select(row => row.CopyText)) + "]";
    public bool Equals(SheetMatrix? other) => ReferenceEquals(this, other) || other is not null && hash == other.hash && rows.AsSpan().SequenceEqual(other.rows);
    public override bool Equals(object? obj) => obj is SheetMatrix other && Equals(other);
    public override int GetHashCode() => hash;
    public override string ToString() => Display;
}
