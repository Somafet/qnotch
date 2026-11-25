using System.Globalization;

namespace Calc.Core;

internal static class DateSyntax
{
    private static readonly Dictionary<string, int> months = new(StringComparer.OrdinalIgnoreCase);
    static DateSyntax()
    {
        string[] names = ["january","february","march","april","may","june","july","august","september","october","november","december"];
        for (var index = 0; index < names.Length; index++) { months[names[index]] = index + 1; months[names[index][..3]] = index + 1; }
        months["sept"] = 9;
    }
    internal static int IsoLength(string source, int start)
    {
        if (source.Length - start < 7 || source[start + 4] != '-') return 0;
        for (var index = 0; index < 4; index++) if (!char.IsAsciiDigit(source[start + index])) return 0;
        var cursor = start + 5; var monthStart = cursor;
        while (cursor < source.Length && cursor - monthStart < 3 && char.IsAsciiDigit(source[cursor])) cursor++;
        if (cursor == monthStart || cursor >= source.Length || source[cursor] != '-') return 0;
        var dayStart = ++cursor;
        while (cursor < source.Length && cursor - dayStart < 3 && char.IsAsciiDigit(source[cursor])) cursor++;
        return cursor == dayStart ? 0 : cursor - start;
    }
    internal static bool TryLiteral(IReadOnlyList<Token> tokens, int position, out DateOnly date, out int length)
    {
        date = default; length = 0;
        if (position >= tokens.Count) return false;
        if (tokens[position].Kind == TokenKind.Date)
        {
            if (!DateOnly.TryParseExact(tokens[position].Text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out date)) throw new FormatException("Invalid Gregorian date");
            length = 1; return true;
        }
        var cursor = position; var monthFirst = months.TryGetValue(tokens[cursor].Text, out var month);
        string day, year;
        if (monthFirst)
        {
            if (++cursor >= tokens.Count || tokens[cursor].Kind != TokenKind.Number) return false;
            day = tokens[cursor++].Text;
            if (cursor < tokens.Count && tokens[cursor].Text == ",") cursor++;
            if (cursor >= tokens.Count || tokens[cursor].Kind != TokenKind.Number) return false;
            year = tokens[cursor++].Text;
        }
        else
        {
            if (cursor + 2 >= tokens.Count || tokens[cursor].Kind != TokenKind.Number || !months.TryGetValue(tokens[cursor + 1].Text, out month) || tokens[cursor + 2].Kind != TokenKind.Number) return false;
            day = tokens[cursor].Text; year = tokens[cursor + 2].Text; cursor += 3;
        }
        if (!int.TryParse(day, NumberStyles.None, CultureInfo.InvariantCulture, out var d) || year.Length != 4 || !int.TryParse(year, NumberStyles.None, CultureInfo.InvariantCulture, out var y)) throw new FormatException("Date requires a day and four-digit year");
        try { date = new(y, month, d); } catch (ArgumentOutOfRangeException) { throw new FormatException("Invalid Gregorian date"); }
        length = cursor - position; return true;
    }
    internal static bool IsNaturalStart(IReadOnlyList<Token> tokens, HashSet<string> names)
    {
        if (tokens.Count == 0 || names.Contains(string.Join(' ', tokens.Select(token => token.Text)))) return false;
        var first = tokens[0].Text.ToLowerInvariant(); var second = tokens.Count > 1 ? tokens[1].Text.ToLowerInvariant() : "";
        if (names.Contains(tokens[0].Text) || second == "(") return false;
        if (ExpressionParser.WorkdayPrefix(tokens, 0, out _)) return true;
        return first is "today" or "tomorrow" or "yesterday" or "christmas" or "until" || first == "in" ||
            Enum.TryParse<DayOfWeek>(first, true, out _) || first == "new" && second is "year" or "years" || TryRecurringLiteral(tokens, 0, out _, out _, out _) ||
            first is "days" or "weeks" && second is "between" or "since" or "until" || first == "age" && second == "of" ||
            first is "next" or "last" && Enum.TryParse<DayOfWeek>(second, true, out _);
    }
    internal static bool TryRecurringLiteral(IReadOnlyList<Token> tokens, int position, out int month, out int day, out int length)
    {
        month = day = length = 0;
        if (position + 1 >= tokens.Count) return false;
        string dayText;
        if (months.TryGetValue(tokens[position].Text, out month) && tokens[position + 1].Kind == TokenKind.Number)
            dayText = tokens[position + 1].Text;
        else if (tokens[position].Kind == TokenKind.Number && months.TryGetValue(tokens[position + 1].Text, out month))
            dayText = tokens[position].Text;
        else return false;
        if (!int.TryParse(dayText, NumberStyles.None, CultureInfo.InvariantCulture, out day) || day < 1 || day > DateTime.DaysInMonth(2000, month)) throw new FormatException("Invalid recurring Gregorian date");
        length = 2; return true;
    }
}
