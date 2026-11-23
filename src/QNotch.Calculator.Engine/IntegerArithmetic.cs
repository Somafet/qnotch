using System.Numerics;

namespace Calc.Core;

internal sealed class IntegerArithmetic(ExecutionBudget budget, CancellationToken token)
{
    internal const string Convention = "Exact integers; finite words wrap modulo 2^width; matching word width/sign required; signed >> sign-extends, >>> zero-fills; shift counts are not masked; ^ is power, xor is exclusive-or; division keeps an exact fraction when needed";
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "hex" or "bin" or "oct" or "dec" or "uint" or "sint" or "bitand" or "bitor" or "bitxor" or "bitnot" or "shl" or "shr" or "ushr";
    internal static void ValidateArity(string name, int count)
    {
        var arity = name.ToLowerInvariant() is "hex" or "bin" or "oct" or "dec" or "bitnot" ? 1 : 2;
        if (count != arity) throw new FormatException($"{name} expects {arity} argument(s)");
    }
    private void Step() => budget.Step(token);
    private SheetValue Make(BigInteger value, int radix = 10, int? width = null, bool signed = false)
    {
        // Charge bounded rendering work to the same budget as all nested calls.
        for (long i = 0; i <= Math.Max(BigInteger.Abs(value).GetBitLength(), width ?? 0); i += 64) Step();
        return new(new IntegerValue(value, radix, width, signed));
    }
    internal static bool IsExactInteger(SheetValue value) => value.Kind == SheetValueKind.Integer || value.Kind == SheetValueKind.Number &&
        value.Number.Unit is null && !value.IsPercentage && !value.Number.IsApproximate && value.IsRational && value.Scalar.Denominator.IsOne;
    internal static BigInteger Require(SheetValue value) => IsExactInteger(value) ? value.Kind == SheetValueKind.Integer ? value.Integer.Value : value.Scalar.Numerator :
        throw new ArithmeticException("Expected an exact dimensionless integer (no percentage)");
    internal SheetValue Literal(string text)
    {
        var radix = char.ToLowerInvariant(text[1]) switch { 'x' => 16, 'b' => 2, 'o' => 8, _ => throw new FormatException("Invalid integer prefix") };
        BigInteger value = 0; var digitSeen = false; var underscore = false;
        foreach (var c in text.AsSpan(2))
        {
            Step();
            if (c == '_') { if (!digitSeen || underscore) throw new FormatException("Misplaced integer separator"); underscore = true; continue; }
            var digit = c is >= '0' and <= '9' ? c - '0' : c is >= 'a' and <= 'f' ? c - 'a' + 10 : c is >= 'A' and <= 'F' ? c - 'A' + 10 : -1;
            if (digit < 0 || digit >= radix) throw new FormatException("Invalid integer digit");
            value = value * radix + digit; digitSeen = true; underscore = false;
            if (value.GetBitLength() > IntegerValue.MaximumBits) throw new ArithmeticException("Integer precision limit exceeded");
        }
        if (!digitSeen || underscore) throw new FormatException("Invalid integer literal");
        return Make(value, radix);
    }
    internal SheetValue Convert(SheetValue value, int? radix, int? width, bool signed)
    {
        Step(); var source = value.Kind == SheetValueKind.Integer ? value.Integer : null;
        return Make(Require(value), radix ?? source?.Radix ?? 10, width ?? source?.Width, width is null ? source?.Signed ?? false : signed);
    }
    private static IntegerValue? Profile(SheetValue left, SheetValue right)
    {
        var a = left.Kind == SheetValueKind.Integer ? left.Integer : null; var b = right.Kind == SheetValueKind.Integer ? right.Integer : null;
        if (a?.Width is not null && b?.Width is not null && (a.Width != b.Width || a.Signed != b.Signed)) throw new ArithmeticException("Cast mixed integer widths/signs explicitly");
        return a?.Width is not null ? a : b?.Width is not null ? b : a ?? b;
    }
    internal bool TryUnary(string op, SheetValue arg, out SheetValue result)
    {
        result = default;
        if (op != "~" && (arg.Kind != SheetValueKind.Integer || op is not ("+" or "-"))) return false;
        Step(); var n = Require(arg); var p = arg.Kind == SheetValueKind.Integer ? arg.Integer : null;
        result = Make(op == "~" ? ~n : op == "-" ? -n : n, p?.Radix ?? 10, p?.Width, p?.Signed ?? false); return true;
    }
    internal bool TryBinary(string op, SheetValue left, SheetValue right, out SheetValue result)
    {
        result = default;
        var bitwise = op is "&" or "|" or "xor" or "<<" or ">>" or ">>>";
        if (!bitwise && (left.Kind != SheetValueKind.Integer && right.Kind != SheetValueKind.Integer || op is not ("+" or "-" or "*" or "/" or "^"))) return false;
        if (!bitwise && (!IsExactInteger(left) || !IsExactInteger(right))) return false;
        Step(); var a = Require(left); var b = Require(right); BigInteger n;
        var shifting = op is "<<" or ">>" or ">>>";
        var p = shifting || op == "^" ? left.Kind == SheetValueKind.Integer ? left.Integer : null : Profile(left, right);
        // A bare integer adopts the word profile, including its signed interpretation.
        BigInteger Word(BigInteger v)
        {
            if (p?.Width is not { } w) return v;
            v &= (BigInteger.One << w) - 1;
            return p.Signed && v >= BigInteger.One << (w - 1) ? v - (BigInteger.One << w) : v;
        }
        a = Word(a); if (!shifting && op != "^") b = Word(b);
        if (shifting)
        {
            if (b < 0 || b > IntegerValue.MaximumBits) throw new ArithmeticException("Shift count must be 0–4096");
            if (op == ">>>" && a.Sign < 0 && p?.Width is null) throw new ArithmeticException("Logical right shift of a negative integer requires a word width");
            var input = op == ">>>" && p?.Width is { } w ? a & ((BigInteger.One << w) - 1) : a;
            n = op == "<<" ? input << (int)b : input >> (int)b;
        }
        else switch (op)
        {
            case "&": n = a & b; break; case "|": n = a | b; break; case "xor": n = a ^ b; break;
            case "+": n = a + b; break; case "-": n = a - b; break; case "*": n = a * b; break;
            case "/":
                if (b.IsZero) throw new DivideByZeroException();
                n = BigInteger.DivRem(a, b, out var remainder); if (!remainder.IsZero) { result = new(new Rational(a, b)); return true; } break;
            case "^":
                if (b < 0) return false;
                if (b > 1024) throw new ArithmeticException("Integer power limit exceeded");
                n = 1;
                for (var i = 0; i < (int)b; i++) { Step(); n = Word(n * a); if (BigInteger.Abs(n).GetBitLength() > IntegerValue.MaximumBits) throw new ArithmeticException("Integer precision limit exceeded"); } break;
            default: return false;
        }
        result = Make(n, left.Kind == SheetValueKind.Integer ? left.Integer.Radix : p?.Radix ?? 10, p?.Width, p?.Signed ?? false); return true;
    }
    internal SheetValue Function(string name, SheetValue[] args)
    {
        ValidateArity(name, args.Length); var key = name.ToLowerInvariant();
        if (key is "hex" or "bin" or "oct" or "dec") return Convert(args[0], key == "hex" ? 16 : key == "bin" ? 2 : key == "oct" ? 8 : 10, null, false);
        if (key is "uint" or "sint")
        {
            var width = Require(args[1]); if (width < 1 || width > IntegerValue.MaximumBits) throw new ArithmeticException("Integer width must be 1–4096 bits");
            return Convert(args[0], 10, (int)width, key == "sint");
        }
        if (key == "bitnot") { TryUnary("~", args[0], out var unary); return unary; }
        TryBinary(key switch { "bitand" => "&", "bitor" => "|", "bitxor" => "xor", "shl" => "<<", "shr" => ">>", _ => ">>>" }, args[0], args[1], out var result); return result;
    }
}
