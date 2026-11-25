using System.Security.Cryptography;
using System.Text;

namespace Calc.Core;

internal sealed class TextArithmetic(ExecutionBudget budget, CancellationToken token)
{
    internal const int MaximumBytes = 65536;
    internal static readonly UTF8Encoding Utf8 = new(false, true);
    internal const string Convention = "Exact UTF-8 text; no BOM, case folding or Unicode normalization; codecs transform text only";
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "text" or "base64" or "decodebase64" or "urlencode" or "urldecode" or "md5" or "sha1" or "sha256";
    internal static void ValidateArity(string name, int count) { if (count != 1) throw new FormatException($"{name} expects 1 argument"); }
    private void Charge(int length) { for (var i = 0; i <= length; i += 64) budget.Step(token); }
    private static string Require(SheetValue value) => value.Kind == SheetValueKind.Text ? value.Text.Value : throw new ArithmeticException("Expected text; use a quoted text argument or text(\"…\")");
    internal SheetValue Literal(string text) { Charge(text.Length); return new(new TextValue(text)); }
    internal (SheetValue Value, TextTransformEvidence Evidence) Function(string name, SheetValue[] args)
    {
        ValidateArity(name, args.Length); var input = Require(args[0]); Charge(input.Length);
        var byteCount = Utf8.GetByteCount(input); if (byteCount > MaximumBytes) throw new ArithmeticException("Text operation exceeds 65536 UTF-8 bytes");
        var bytes = Utf8.GetBytes(input); Charge(bytes.Length); var key = name.ToLowerInvariant(); string output;
        try
        {
            output = key switch
            {
                "text" => input,
                "base64" => ((bytes.Length + 2) / 3) * 4 > TextValue.MaximumLength ? throw new ArithmeticException("Encoded text exceeds output limit") : Convert.ToBase64String(bytes),
                "decodebase64" => DecodeBase64(input),
                "urlencode" => EncodeUrl(bytes), "urldecode" => DecodeUrl(input),
                "md5" => Convert.ToHexStringLower(MD5.HashData(bytes)),
                "sha1" => Convert.ToHexStringLower(SHA1.HashData(bytes)),
                "sha256" => Convert.ToHexStringLower(SHA256.HashData(bytes)),
                _ => throw new FormatException("Unknown text function")
            };
        }
        catch (DecoderFallbackException) { throw new FormatException("Decoded bytes are not valid UTF-8 text"); }
        catch (CryptographicException) { throw new ArithmeticException("Hash algorithm is unavailable on this system"); }
        TextValue.Validate(output); Charge(output.Length);
        var preview = Convert.ToHexStringLower(bytes.AsSpan(0, Math.Min(32, bytes.Length))) + (bytes.Length > 32 ? "…" : "");
        return (new(new TextValue(output)), new(name, input, output, bytes.Length, Utf8.GetByteCount(output), preview, args[0].Display));
    }
    private static string DecodeBase64(string input)
    {
        if (input.Length % 4 != 0 || input.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('+' or '/' or '='))) throw new FormatException("Expected canonical padded standard Base64 without whitespace");
        var bytes = Convert.FromBase64String(input);
        if (Convert.ToBase64String(bytes) != input) throw new FormatException("Noncanonical Base64 padding or pad bits");
        return Utf8.GetString(bytes);
    }
    private string EncodeUrl(byte[] bytes)
    {
        static bool Unreserved(byte b) => b is >= (byte)'A' and <= (byte)'Z' or >= (byte)'a' and <= (byte)'z' or >= (byte)'0' and <= (byte)'9' or (byte)'-' or (byte)'_' or (byte)'.' or (byte)'~';
        var length = bytes.Sum(b => Unreserved(b) ? 1 : 3);
        if (length > TextValue.MaximumLength) throw new ArithmeticException("Encoded text exceeds output limit");
        var result = new StringBuilder(length); const string hex = "0123456789ABCDEF";
        for (var i = 0; i < bytes.Length; i++)
        {
            if ((i & 63) == 0) budget.Step(token); var b = bytes[i];
            if (Unreserved(b)) result.Append((char)b); else result.Append('%').Append(hex[b / 16]).Append(hex[b % 16]);
        }
        return result.ToString();
    }
    private string DecodeUrl(string text)
    {
        var bytes = new List<byte>(); var work = 0; Span<byte> buffer = stackalloc byte[4];
        for (var i = 0; i < text.Length;)
        {
            if ((work++ & 63) == 0) budget.Step(token);
            if (text[i] == '%')
            {
                if (i + 2 >= text.Length || !char.IsAsciiHexDigit(text[i + 1]) || !char.IsAsciiHexDigit(text[i + 2])) throw new FormatException("Invalid URL percent escape");
                static int Digit(char c) => c <= '9' ? c - '0' : char.ToUpperInvariant(c) - 'A' + 10;
                bytes.Add((byte)(16 * Digit(text[i + 1]) + Digit(text[i + 2]))); i += 3;
            }
            else
            {
                var rune = Rune.GetRuneAt(text, i); var length = rune.EncodeToUtf8(buffer);
                for (var j = 0; j < length; j++) bytes.Add(buffer[j]); i += rune.Utf16SequenceLength;
            }
            if (bytes.Count > MaximumBytes) throw new ArithmeticException("Decoded bytes exceed text operation limit");
        }
        return Utf8.GetString(bytes.ToArray());
    }
}
