using System.Text;

namespace Calc.Core;

internal sealed record TextLiteralExpression(string Value) : Expression;

public static class TextSyntax
{
    private static readonly (string Command, string Function)[] Commands = [("chmod", "chmod"), ("unicode", "unicode"), ("decode base64", "decodeBase64"), ("base64", "base64"), ("urlencode", "urlencode"), ("urldecode", "urldecode"), ("sha256", "sha256"), ("sha1", "sha1"), ("md5", "md5")];
    internal static string ReadQuoted(string source, ref int index, CancellationToken token)
    {
        if (source[index++] != '"') throw new FormatException("Expected text quote");
        var result = new StringBuilder(); var start = index;
        while (index < source.Length)
        {
            if ((index & 255) == 0) token.ThrowIfCancellationRequested();
            if (index - start > TextValue.MaximumLength * 6) throw new ArithmeticException("Text literal length limit exceeded");
            var c = source[index++];
            if (c == '"') { var value = result.ToString(); TextValue.Validate(value); return value; }
            if (c < 32) throw new FormatException("Escape control characters inside a text literal");
            if (c != '\\') result.Append(c);
            else
            {
                if (index == source.Length) throw new FormatException("Unclosed text escape");
                var escape = source[index++];
                if (escape == 'u')
                {
                    if (index + 4 > source.Length) throw new FormatException("Incomplete Unicode escape");
                    var value = 0;
                    for (var n = 0; n < 4; n++)
                    {
                        var h = source[index++]; if (!char.IsAsciiHexDigit(h)) throw new FormatException("Invalid Unicode escape");
                        value = value * 16 + (h <= '9' ? h - '0' : char.ToUpperInvariant(h) - 'A' + 10);
                    }
                    result.Append((char)value);
                }
                else result.Append(escape switch { '"' => '"', '\\' => '\\', '/' => '/', 'b' => '\b', 'f' => '\f', 'n' => '\n', 'r' => '\r', 't' => '\t', _ => throw new FormatException("Invalid text escape") });
            }
            if (result.Length > TextValue.MaximumLength) throw new ArithmeticException("Text exceeds 32768 UTF-16 code units");
        }
        throw new FormatException("Unclosed text literal");
    }
    internal static bool DataCallAt(string source, int open)
    {
        var end = open; while (end > 0 && char.IsWhiteSpace(source[end - 1])) end--;
        var start = end; while (start > 0 && (char.IsLetterOrDigit(source[start - 1]) || source[start - 1] == '_')) start--;
        return end > start && end - start <= 128 && (TextArithmetic.IsFunction(source[start..end]) || TableArithmetic.IsFunction(source[start..end]) || DeveloperArithmetic.IsTextFunction(source[start..end]) || source[start..end].Equals("uuid", StringComparison.OrdinalIgnoreCase));
    }
    internal static string? AttemptedDefinitionName(string source)
    {
        var equal = AssignmentIndex(source); if (equal < 0) return null;
        var header = source[..equal].Trim(); var open = header.IndexOf('(');
        return open > 0 && header.EndsWith(')') && FunctionLibrary.ValidIdentifier(header[..open].Trim(), 64) ? header[..open].Trim() : null;
    }
    internal static int AssignmentIndex(string source)
    {
        if (!source.Contains('=')) return -1;
        var quoted = false;
        for (var i = 0; i < source.Length; i++)
        {
            if (quoted && source[i] == '\\') { i++; continue; }
            if (source[i] == '"') quoted = !quoted;
            else if (!quoted && source[i] == '=') return i;
        }
        return -1;
    }
    private static (int Start, int Payload, string Function)? FindNatural(string source)
    {
        (int Start, int Payload, string Function)? At(int start)
        {
            while (start < source.Length && char.IsWhiteSpace(source[start])) start++;
            if (start == source.Length || !char.IsLetter(source[start])) return null;
            foreach (var (command, function) in Commands)
            {
                var cursor = start; var matched = true;
                foreach (var c in command)
                {
                    if (c == ' ')
                    {
                        if (cursor >= source.Length || !char.IsWhiteSpace(source[cursor])) { matched = false; break; }
                        while (cursor < source.Length && char.IsWhiteSpace(source[cursor])) cursor++;
                    }
                    else if (cursor >= source.Length || char.ToUpperInvariant(source[cursor++]) != char.ToUpperInvariant(c)) { matched = false; break; }
                }
                if (!matched || cursor == source.Length || !char.IsWhiteSpace(source[cursor])) continue;
                while (cursor < source.Length && char.IsWhiteSpace(source[cursor])) cursor++;
                if (cursor < source.Length && source[cursor] is not ('=' or '(')) return (start, cursor, function);
            }
            return null;
        }
        if (At(0) is { } whole) return whole;
        var equal = AssignmentIndex(source); if (equal < 0) return null;
        var candidate = At(equal + 1); if (candidate is null) return null;
        var header = source[..equal].Trim(); var open = header.IndexOf('(');
        var plausible = open >= 0 ? header.EndsWith(')') && FunctionLibrary.ValidIdentifier(header[..open].Trim(), 64) :
            header.Length is > 0 and <= 128 && header.Split(' ', StringSplitOptions.RemoveEmptyEntries).All(word => FunctionLibrary.ValidIdentifier(word, 128));
        return plausible ? candidate : null;
    }
    /// <summary>Bounded lexical aid for source highlighting; returns the start of unquoted literal command data.</summary>
    public static int RawPayloadStart(string source)
    {
        if (source.Length > 4096) return -1;
        var found = FindNatural(source); return found is { } command && source[command.Payload] != '"' ? command.Payload : -1;
    }
    internal static string NormalizeNatural(string source, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (FindNatural(source) is not { } command) return source;
        var (start, payload, function) = command;
        if (source[payload] == '"')
        {
            var end = payload; _ = ReadQuoted(source, ref end, token);
            return source[..start] + function + "(" + source[payload..end] + ")" + source[end..];
        }
        var value = source[payload..].Trim(); TextValue.Validate(value);
        return source[..start] + function + "(" + TextValue.Quote(value) + ")";
    }
}
