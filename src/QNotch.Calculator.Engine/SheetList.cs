using System.Text;

namespace Calc.Core;

/// <summary>Immutable flat numeric/monetary data. The result preview never limits the stored values.</summary>
public sealed class SheetList : IEquatable<SheetList>
{
    public const int MaxItems = 1024;
    private readonly SheetValue[] values;
    private readonly int hash;
    public IReadOnlyList<SheetValue> Values { get; }
    public bool IsApproximate { get; }
    public bool HasMoney { get; }
    /// <summary>Optional per-value labels, kept by table selections for charts.</summary>
    public IReadOnlyList<string>? Labels { get; }
    public SheetList(IEnumerable<SheetValue> items, IReadOnlyList<string>? labels = null)
    {
        var copy = new List<SheetValue>(); var hashCode = new HashCode();
        foreach (var item in items)
        {
            if (copy.Count == MaxItems) throw new ArithmeticException("List exceeds 1024 values");
            if (item.Kind is not SheetValueKind.Number and not SheetValueKind.Money) throw new ArithmeticException("Lists require flat numeric or monetary values; use rectangular numeric rows for matrices");
            copy.Add(item); hashCode.Add(item);
            IsApproximate |= item.Kind == SheetValueKind.Money ? item.Money.Magnitude.IsApproximate : item.Number.IsApproximate;
            HasMoney |= item.Kind == SheetValueKind.Money;
        }
        values = copy.ToArray(); Values = Array.AsReadOnly(values);
        if (labels is not null)
        {
            if (labels.Count != values.Length) throw new ArithmeticException("List labels do not match its values");
            Labels = Array.AsReadOnly(labels.ToArray());
            foreach (var label in Labels) hashCode.Add(label, StringComparer.Ordinal);
        }
        hash = hashCode.ToHashCode();
    }
    public string Display
    {
        get
        {
            var text = new StringBuilder("["); var displayed = 0;
            foreach (var item in values)
            {
                if (displayed == 16) break;
                var next = item.Display;
                if (text.Length + next.Length > 512) break;
                if (displayed++ > 0) text.Append(", ");
                text.Append(next);
            }
            if (displayed < values.Length) text.Append(displayed > 0 ? ", …" : "…");
            return text.Append(']').ToString();
        }
    }
    // Complete formatted values, including approximation markers; bounded by MaxItems and each value's output limit.
    public string CopyText => "[" + string.Join(", ", values.Select(value => value.Display)) + "]";
    public bool Equals(SheetList? other) => ReferenceEquals(this, other) || other is not null && hash == other.hash && values.AsSpan().SequenceEqual(other.values) && (Labels ?? []).SequenceEqual(other.Labels ?? [], StringComparer.Ordinal);
    public override bool Equals(object? obj) => obj is SheetList other && Equals(other);
    public override int GetHashCode() => hash;
    public override string ToString() => Display;
}
