namespace Calc.Core;

internal sealed record IpLiteralExpression(string Text) : Expression;
internal sealed record NetworkMembershipExpression(Expression Address, Expression Subnet) : Expression;
internal sealed record PrefixMaskExpression(int Prefix, int Family) : Expression;

internal sealed partial class ExpressionParser
{
    private static int IpLiteralLength(string source, int start)
    {
        // Check the shape before other numeric/date grammars; ordinary clocks retain their existing tokens.
        var i = start;
        while (i < source.Length && (char.IsLetterOrDigit(source[i]) || source[i] is '.' or ':' or '%' or '_'))
        { if (i - start >= 128) break; i++; }
        var candidate = source.AsSpan(start, i - start);
        var dots = candidate.Count('.'); var colons = candidate.Count(':');
        return dots >= 3 || colons >= 3 || candidate.Contains("::", StringComparison.Ordinal) ? i - start : 0;
    }
    private bool TryNetworkConversion(ref Expression expression, bool membershipAllowed)
    {
        if (Take("cidr")) { expression = new CallExpression("cidr", [expression]); return true; }
        if (Take("mask")) { expression = new CallExpression("subnetmask", [expression]); return true; }
        if (!membershipAllowed) return false;
        var starts = Current.Kind == TokenKind.Ip || Current.Text == "(" || NetworkArithmetic.IsFunction(Current.Text) && position + 1 < tokens.Count && tokens[position + 1].Text == "(";
        if (!starts && KnownNameLength(position) > 0)
        {
            var probe = position; var saved = position; var zone = TryZone(out _, true); position = saved;
            starts = !zone && Current.Text.ToLowerInvariant() is not ("eng" or "engineering" or "colors" or "colours" or "unix") &&
                !UnitParser.TryParse(tokens, ref probe, null, out _) && !IntegerTarget() &&
                !CurrencyCatalog.TryMatch(tokens, position, out _, out _) && !EarningsTarget(Current.Text, out _);
        }
        if (!starts) return false;
        expression = new NetworkMembershipExpression(expression, Product()); return true;
    }
    private Expression ParsePrefixMask()
    {
        if (Current.Kind != TokenKind.Number || !int.TryParse(Current.Text, out var prefix)) throw new FormatException("Expected a whole CIDR prefix");
        position++; var family = 4;
        if (Take("ipv6")) family = 6; else _ = Take("ipv4");
        if (!Take("mask")) throw new FormatException("Expected mask after /prefix");
        if (prefix < 0 || prefix > (family == 4 ? 32 : 128)) throw new ArithmeticException("Prefix is outside the address family's bit width");
        return new PrefixMaskExpression(prefix, family);
    }
}
