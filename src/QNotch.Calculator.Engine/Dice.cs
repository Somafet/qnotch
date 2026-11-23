using System.Globalization;
using System.Text;

namespace Calc.Core;

public enum DiceSelection { All, KeepHighest, KeepLowest, DropHighest, DropLowest }
/// <summary><c>crit</c> rolls every dice group twice; <c>crit!</c> (crunchy) adds each group's maximum to one roll. Modifiers count once.</summary>
public enum DiceCrit { None, Double, Maximum }

/// <summary>One signed term of a dice line: a group of identical dice, or a whole-number modifier when <see cref="Sides"/> is 0.</summary>
public sealed record DiceTerm(int Sign, int Count, int Sides, DiceSelection Selection = DiceSelection.All, int Select = 0, long Constant = 0)
{
    public bool IsDice => Sides > 0;
    /// <summary>How many of the group's dice count toward its subtotal.</summary>
    public int Kept => Selection switch
    {
        DiceSelection.KeepHighest or DiceSelection.KeepLowest => Select,
        DiceSelection.DropHighest or DiceSelection.DropLowest => Count - Select,
        _ => Count,
    };
    internal string Notation
    {
        get
        {
            if (!IsDice) return Constant.ToString(CultureInfo.InvariantCulture);
            var text = Count.ToString(CultureInfo.InvariantCulture) + "d" + Sides.ToString(CultureInfo.InvariantCulture);
            return Selection switch
            {
                DiceSelection.KeepHighest => text + "kh" + Select.ToString(CultureInfo.InvariantCulture),
                DiceSelection.KeepLowest => text + "kl" + Select.ToString(CultureInfo.InvariantCulture),
                DiceSelection.DropHighest => text + "dh" + Select.ToString(CultureInfo.InvariantCulture),
                DiceSelection.DropLowest => text + "dl" + Select.ToString(CultureInfo.InvariantCulture),
                _ => text,
            };
        }
    }
}

/// <summary>A parsed dice line such as <c>10d6+4</c>, <c>2d20kh1+5</c>, <c>crit 2d6+3</c> or <c>crit! 2d6+3</c>. Immutable and entropy-free.</summary>
public sealed class DiceFormula
{
    public DiceCrit Crit { get; }
    /// <summary>How many times each dice group is rolled.</summary>
    public int Copies => Crit == DiceCrit.Double ? 2 : 1;
    public IReadOnlyList<DiceTerm> Terms { get; }
    /// <summary>Canonical notation; the persisted roll is valid only for this exact formula.</summary>
    public string Notation { get; }
    /// <summary>Sides of every die in roll order: each group, followed by its second roll on a <c>crit</c>.</summary>
    public IReadOnlyList<int> Sides { get; }
    internal DiceFormula(DiceCrit crit, IReadOnlyList<DiceTerm> terms)
    {
        Crit = crit; Terms = terms;
        var notation = new StringBuilder(crit switch { DiceCrit.Double => "crit ", DiceCrit.Maximum => "crit! ", _ => "" });
        for (var i = 0; i < terms.Count; i++)
        {
            if (terms[i].Sign < 0) notation.Append('-'); else if (i > 0) notation.Append('+');
            notation.Append(terms[i].Notation);
        }
        Notation = notation.ToString();
        Sides = terms.Where(t => t.IsDice).SelectMany(t => Enumerable.Repeat(t.Sides, t.Count * Copies)).ToArray();
    }
    /// <summary>A stored roll belongs to this formula only when every face is a possible result of its die.</summary>
    public bool Fits(IReadOnlyList<int>? faces) => faces is not null && faces.Count == Sides.Count && faces.Select((face, i) => face >= 1 && face <= Sides[i]).All(ok => ok);
}

/// <summary>A document-owned roll for one statement. Core never rolls; the document owner supplies faces.</summary>
public sealed record DiceBinding(Guid Statement, string Formula, int[] Faces);
public readonly record struct DieFace(int Sides, int Face, bool Kept);

internal sealed record DiceExpression(DiceFormula Formula) : Expression;

/// <summary>An unrolled dice line: no value, a muted range preview and its explanation.</summary>
internal sealed class DiceUnrolledException(string preview, CalculationStep[] steps) : FormatException("Press Enter to roll")
{
    internal string Preview { get; } = preview;
    internal CalculationStep[] Steps { get; } = steps;
}

public static class DiceSyntax
{
    public const int MaxDicePerLine = 1000;
    public const int MaxSides = 10_000;
    public const int MaxTerms = 32;
    public const long MaxModifier = 1_000_000;
    public const int MaxLabelWords = 8;
    internal const string RollNote = "Ctrl+Enter rolls again; editing the dice clears the roll";
    internal const string CritNote = "Critical: each dice group is rolled twice; modifiers count once";
    internal const string CrunchyNote = "Crunchy critical: each dice group adds its maximum to its rolled dice; modifiers count once";

    /// <summary>Parses a dice line's expression text. Optional leading label words are ignored, as with numeric labels.
    /// A user variable named like a count-less die (<c>d6</c>) shadows the dice reading.</summary>
    public static DiceFormula? TryParse(string text, IReadOnlySet<string>? names = null)
    {
        if (text.Length is 0 or > 4096) return null;
        var position = 0;
        for (var words = 0; ; words++)
        {
            if (Parse(text, position, names) is { } formula) return formula;
            if (words >= MaxLabelWords || !SkipLabelWord(text, ref position, names)) return null;
        }
    }

    /// <summary>The dice formula on each source line, using the sheet's own variable names for shadowing. One pass over the sheet.</summary>
    public static IReadOnlyDictionary<int, DiceFormula> Formulas(string source, CancellationToken token = default)
    {
        var found = new Dictionary<int, DiceFormula>();
        if (!Mentions(source)) return found;
        var lines = source.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        if (lines.Length > SheetEvaluator.MaxLines || source.Length > SheetEvaluator.MaxCharacters) return found;
        var scanned = new ParsedLine[lines.Length];
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < lines.Length; i++)
        {
            token.ThrowIfCancellationRequested();
            scanned[i] = SheetSyntax.Scan(lines[i], token);
            if (scanned[i].Assignment is { } name) names.Add(name);
        }
        for (var i = 0; i < lines.Length; i++)
        {
            var line = scanned[i];
            if (line.Error is not null || line.Boundary || line.Directive is not null || line.FunctionName is not null || line.Text.Length == 0) continue;
            if (TryParse(line.Text, names) is { } formula) found[i] = formula;
        }
        return found;
    }

    /// <summary>A cheap pre-check: some <c>d</c> directly followed by a digit or <c>%</c>.</summary>
    public static bool Mentions(string source)
    {
        for (var i = source.IndexOfAny(['d', 'D']); i >= 0 && i + 1 < source.Length; i = source.IndexOfAny(['d', 'D'], i + 1))
            if (char.IsAsciiDigit(source[i + 1]) || source[i + 1] == '%') return true;
        return false;
    }

    private static bool SkipLabelWord(string text, ref int position, IReadOnlySet<string>? names)
    {
        var start = position;
        while (position < text.Length && char.IsWhiteSpace(text[position])) position++;
        var wordStart = position;
        while (position < text.Length && (char.IsLetter(text[position]) || text[position] == '_')) position++;
        if (position == wordStart || position < text.Length && !char.IsWhiteSpace(text[position])) { position = start; return false; }
        var word = text[wordStart..position];
        if (word.Equals("crit", StringComparison.OrdinalIgnoreCase) || names?.Contains(word) == true) { position = start; return false; }
        return true;
    }

    private static DiceFormula? Parse(string text, int position, IReadOnlySet<string>? names)
    {
        void Skip() { while (position < text.Length && char.IsWhiteSpace(text[position])) position++; }
        Skip();
        var crit = DiceCrit.None;
        if (string.Compare(text, position, "crit", 0, 4, StringComparison.OrdinalIgnoreCase) == 0 && names?.Contains("crit") != true)
        {
            // `crit!` may touch the dice; `crit` needs a space after it.
            if (position + 4 < text.Length && text[position + 4] == '!') { crit = DiceCrit.Maximum; position += 5; Skip(); }
            else if (position + 4 < text.Length && char.IsWhiteSpace(text[position + 4])) { crit = DiceCrit.Double; position += 4; Skip(); }
        }
        var terms = new List<DiceTerm>(); var dice = 0;
        while (true)
        {
            Skip();
            var sign = 1;
            if (position < text.Length && text[position] is '+' or '-') { sign = text[position] == '-' ? -1 : 1; position++; Skip(); }
            else if (terms.Count > 0) return null;
            if (position >= text.Length) return null;
            var start = position;
            var count = ReadNumber(text, ref position);
            if (count == -2) return null;
            if (position < text.Length && text[position] is 'd' or 'D')
            {
                position++;
                int sides;
                if (position < text.Length && text[position] == '%')
                {
                    // `d%` is a percentage of a sheet variable named d.
                    if (count == -1 && names?.Contains("d") == true) return null;
                    sides = 100; position++;
                }
                else { sides = (int)Math.Min(int.MaxValue, ReadNumber(text, ref position)); if (sides < 0) return null; }
                // A count-less die named like a sheet variable is that variable.
                if (count == -1 && names?.Contains(text[start..position]) == true) return null;
                var number = count == -1 ? 1 : count;
                if (number is < 1 or > MaxDicePerLine || sides is < 1 or > MaxSides || (dice += (int)number) > MaxDicePerLine) return null;
                var selection = DiceSelection.All; var select = 0;
                if (position < text.Length && text[position] is 'k' or 'K' or 'd' or 'D')
                {
                    var keep = text[position] is 'k' or 'K'; position++;
                    var high = true;
                    if (position < text.Length && text[position] is 'h' or 'H' or 'l' or 'L') { high = text[position] is 'h' or 'H'; position++; }
                    else if (!keep) return null;
                    var amount = ReadNumber(text, ref position);
                    if (amount < 1) return null;
                    selection = keep ? high ? DiceSelection.KeepHighest : DiceSelection.KeepLowest : high ? DiceSelection.DropHighest : DiceSelection.DropLowest;
                    if (keep ? amount > number : amount >= number) return null;
                    select = (int)amount;
                }
                terms.Add(new(sign, (int)number, sides, selection, select));
            }
            else if (count >= 0)
            {
                if (count > MaxModifier) return null;
                terms.Add(new(sign, 0, 0, Constant: count));
            }
            else return null;
            if (terms.Count > MaxTerms) return null;
            if (position < text.Length && !char.IsWhiteSpace(text[position]) && text[position] is not ('+' or '-')) return null;
            Skip();
            if (position >= text.Length) break;
        }
        // A doubled crit rolls twice as many dice; the per-line bound covers them all.
        return dice == 0 || crit == DiceCrit.Double && dice * 2 > MaxDicePerLine ? null : new DiceFormula(crit, terms);
    }

    /// <summary>Reads ASCII digits: -1 when none, -2 when the value is out of range.</summary>
    private static long ReadNumber(string text, ref int position)
    {
        var start = position; long value = 0;
        while (position < text.Length && char.IsAsciiDigit(text[position]))
        {
            value = value * 10 + (text[position] - '0'); position++;
            if (value > MaxModifier * 10) return -2;
        }
        return position == start ? -1 : value;
    }

    /// <summary>Every rolled die in roll order, for presentation.</summary>
    public static IReadOnlyList<DieFace> Faces(DiceFormula formula, IReadOnlyList<int> faces)
    {
        if (!formula.Fits(faces)) throw new ArgumentException("Roll does not belong to this formula");
        var dice = new List<DieFace>(faces.Count); var offset = 0;
        foreach (var term in formula.Terms.Where(t => t.IsDice))
            for (var copy = 0; copy < formula.Copies; copy++)
            {
                var rolled = faces.Skip(offset).Take(term.Count).ToArray(); offset += term.Count;
                var kept = KeptMask(term, rolled);
                for (var i = 0; i < rolled.Length; i++) dice.Add(new(term.Sides, rolled[i], kept[i]));
            }
        return dice;
    }

    /// <summary>Indices of the dice that count toward their group, in roll order.</summary>
    internal static bool[] KeptMask(DiceTerm term, ReadOnlySpan<int> faces)
    {
        var kept = new bool[faces.Length];
        if (term.Selection == DiceSelection.All) { Array.Fill(kept, true); return kept; }
        var order = Enumerable.Range(0, faces.Length).ToArray();
        var values = faces.ToArray();
        // Stable: equal faces resolve in roll order.
        var high = term.Selection is DiceSelection.KeepHighest or DiceSelection.DropLowest;
        order = high ? order.OrderByDescending(i => values[i]).ThenBy(i => i).ToArray() : order.OrderBy(i => values[i]).ThenBy(i => i).ToArray();
        foreach (var i in order.Take(term.Kept)) kept[i] = true;
        return kept;
    }

    internal static (long Total, CalculationStep[] Steps) Total(DiceFormula formula, IReadOnlyList<int> faces)
    {
        var steps = new List<CalculationStep>(); var parts = new List<string>(); var summary = new StringBuilder();
        long total = 0; var offset = 0; var listed = 0;
        foreach (var term in formula.Terms)
        {
            if (summary.Length > 0 || term.Sign < 0) summary.Append(term.Sign < 0 ? (summary.Length > 0 ? " − " : "−") : " + ");
            if (!term.IsDice)
            {
                total += term.Sign * term.Constant;
                parts.Add((term.Sign < 0 ? "−" : "+") + Format(term.Constant));
                summary.Append(Format(term.Constant));
                continue;
            }
            long sum = 0;
            for (var copy = 0; copy < formula.Copies; copy++)
            {
                var rolled = faces.Skip(offset).Take(term.Count).ToArray(); offset += term.Count;
                var kept = KeptMask(term, rolled);
                long subtotal = 0; for (var i = 0; i < rolled.Length; i++) if (kept[i]) subtotal += rolled[i];
                string Face(int i) => kept[i] ? Format(rolled[i]) : "(" + Format(rolled[i]) + ")";
                var shown = Enumerable.Range(0, Math.Min(60, rolled.Length)).Select(Face).ToList();
                if (rolled.Length > 60) shown.Add("… " + Format(rolled.Length - 60) + " more");
                var dropped = term.Selection == DiceSelection.All ? null : "Parenthesized dice are dropped";
                steps.Add(copy == 0 ? new(term.Notation, shown, Format(subtotal), dropped)
                    : new("crit " + term.Notation + " again", shown, Format(subtotal), dropped is null ? CritNote : CritNote + "; " + dropped));
                // The hover note lists the actual dice, bounded.
                if (copy > 0) summary.Append(" + ");
                var room = Math.Max(1, 24 - listed); listed += Math.Min(room, rolled.Length);
                summary.Append('[').Append(string.Join(", ", Enumerable.Range(0, Math.Min(room, rolled.Length)).Select(Face)));
                summary.Append(rolled.Length > room ? ", …]" : "]");
                sum += subtotal;
            }
            var maximum = formula.Crit == DiceCrit.Maximum ? (long)term.Kept * term.Sides : 0;
            if (maximum > 0)
            {
                steps.Add(new("crit! " + term.Notation, [Format(maximum) + " max", Format(sum) + " rolled"], Format(maximum + sum), CrunchyNote));
                summary.Insert(summary.ToString().LastIndexOf('['), Format(maximum) + " + ");
            }
            sum += maximum;
            total += term.Sign * sum;
            parts.Add((term.Sign < 0 ? "−" : "+") + Format(sum));
        }
        if (parts.Count > 0 && parts[0].StartsWith('+')) parts[0] = parts[0][1..];
        steps.Add(new("roll " + formula.Notation, parts, Format(total), summary + "; " + RollNote));
        return (total, steps.ToArray());
    }

    /// <summary>The muted preview of an unrolled line: its possible range, with the average in the explanation.</summary>
    internal static (string Preview, CalculationStep[] Steps) Preview(DiceFormula formula)
    {
        long minimum = 0, maximum = 0; var average = 0.0; var exact = true;
        foreach (var term in formula.Terms)
        {
            long low, high; double mean; bool exactMean;
            if (!term.IsDice) { low = high = term.Constant; mean = term.Constant; exactMean = true; }
            else
            {
                low = term.Kept; high = (long)term.Kept * term.Sides;
                (mean, exactMean) = GroupAverage(term);
                if (formula.Crit == DiceCrit.Double) { low *= 2; high *= 2; mean *= 2; }
                if (formula.Crit == DiceCrit.Maximum) { var bonus = (long)term.Kept * term.Sides; low += bonus; high += bonus; mean += bonus; }
            }
            if (term.Sign < 0) (low, high, mean) = (-high, -low, -mean);
            minimum += low; maximum += high; average += mean; exact &= exactMean;
        }
        var range = minimum == maximum ? Format(minimum) : Format(minimum) + "–" + Format(maximum);
        var averageText = double.IsNaN(average) ? null : exact ? "average " + Format(average) : "average ≈" + Format(average);
        var note = (averageText is null ? "" : averageText + "; ") + "press Enter to roll" + formula.Crit switch { DiceCrit.Double => "; " + CritNote, DiceCrit.Maximum => "; " + CrunchyNote, _ => "" };
        return (range, [new("range " + formula.Notation, [], range, note)]);
    }

    private static string Format(long value) => value < 0 ? "−" + (-value).ToString(CultureInfo.InvariantCulture) : value.ToString(CultureInfo.InvariantCulture);
    private static string Format(double value)
    {
        var text = Math.Round(Math.Abs(value), 2).ToString("0.##", CultureInfo.InvariantCulture);
        return value < 0 && text != "0" ? "−" + text : text;
    }

    /// <summary>Expected group subtotal. Plain groups are exact; kept/dropped groups use order statistics up to a bound, else NaN.</summary>
    private static (double Mean, bool Exact) GroupAverage(DiceTerm term)
    {
        if (term.Selection == DiceSelection.All) return (term.Count * (term.Sides + 1) / 2.0, true);
        if (term.Count > 100 || term.Sides > 1000) return (double.NaN, false);
        // E[sum of the k highest] = Σ_j E[X_(j)], where P(X_(j) ≥ x) is the chance that at least n−j+1 dice show ≥ x.
        var n = term.Count; var high = term.Selection is DiceSelection.KeepHighest or DiceSelection.DropLowest;
        var mean = 0.0;
        for (var x = 1; x <= term.Sides; x++)
        {
            var p = (term.Sides - x + 1) / (double)term.Sides;
            var atLeast = new double[n + 2]; // atLeast[m] = P(at least m dice ≥ x)
            var pmf = new double[n + 1];
            for (var m = 0; m <= n; m++) pmf[m] = Binomial(n, m) * Math.Pow(p, m) * Math.Pow(1 - p, n - m);
            for (var m = n; m >= 0; m--) atLeast[m] = atLeast[m + 1] + pmf[m];
            // The kept dice are the top k (high) or bottom k (low): ranks n..n−k+1 or 1..k.
            for (var r = 1; r <= term.Kept; r++)
            {
                var rank = high ? n - r + 1 : r; // rank-th smallest
                mean += atLeast[n - rank + 1];
            }
        }
        return (mean, false);
    }
    private static double Binomial(int n, int k)
    {
        double result = 1; k = Math.Min(k, n - k);
        for (var i = 1; i <= k; i++) result = result * (n - k + i) / i;
        return result;
    }
}
