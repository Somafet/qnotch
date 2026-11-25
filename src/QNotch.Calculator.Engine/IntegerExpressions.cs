namespace Calc.Core;

internal sealed record IntegerLiteralExpression(string Text) : Expression;
internal sealed record IntegerConvertExpression(Expression Operand, int? Radix, int? Width, bool Signed) : Expression;

internal sealed partial class ExpressionParser
{
    private static int? IntegerBase(string text) => text.ToLowerInvariant() switch
    { "hex" or "hexadecimal" => 16, "bin" or "binary" => 2, "oct" or "octal" => 8, "dec" or "decimal" => 10, _ => null };
    private static bool WordType(string text, out int width, out bool signed)
    {
        signed = text.StartsWith('i') || text.StartsWith('I'); width = 0;
        return text.Length > 1 && (signed || text.StartsWith('u') || text.StartsWith('U')) &&
            text.AsSpan(1).ContainsAnyExceptInRange('0', '9') == false && int.TryParse(text.AsSpan(1), out width);
    }
    private bool IntegerTarget() => IntegerBase(Current.Text) is not null || WordType(Current.Text, out _, out _);
    private bool TryIntegerConversion(ref Expression expression)
    {
        var radix = IntegerBase(Current.Text); int? width = null; var signed = false;
        if (radix is not null) position++;
        if (WordType(Current.Text, out var w, out signed)) { width = w; position++; radix ??= 10; }
        else if (radix is not null && Current.Kind == TokenKind.Number && position + 1 < tokens.Count && tokens[position + 1].Text.Equals("bits", StringComparison.OrdinalIgnoreCase))
        {
            if (!int.TryParse(Current.Text, out w)) throw new FormatException("Expected whole integer width");
            width = w; position += 2;
        }
        if (radix is null) return false;
        if (width is < 1 or > IntegerValue.MaximumBits) throw new ArithmeticException("Integer width must be 1–4096 bits");
        expression = new IntegerConvertExpression(expression, radix, width, signed); return true;
    }
    private Expression BitOr()
    {
        var value = BitXor(); while (Take("|")) value = new BinaryExpression("|", value, BitXor()); return value;
    }
    private Expression BitXor()
    {
        var value = BitAnd(); while (Take("xor")) value = new BinaryExpression("xor", value, BitAnd()); return value;
    }
    private Expression BitAnd()
    {
        var value = Shift(); while (Take("&")) value = new BinaryExpression("&", value, Shift()); return value;
    }
    private Expression Shift()
    {
        var value = Sum();
        while (Current.Text is "<<" or ">>" or ">>>") { var op = Current.Text; position++; value = new BinaryExpression(op, value, Sum()); }
        return value;
    }
}
