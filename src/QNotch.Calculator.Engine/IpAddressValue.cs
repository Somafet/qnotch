using System.Globalization;
using System.Net;
using System.Numerics;

namespace Calc.Core;

/// <summary>Numeric IP literal only: no resolver, socket, interface or OS address state.</summary>
public sealed record IpAddressValue
{
    public int BitWidth { get; }
    public BigInteger Number { get; }
    public string Text { get; }
    internal IpAddressValue(BigInteger number, int width)
    {
        if (width is not (32 or 128) || number < 0 || number >= BigInteger.One << width) throw new ArithmeticException("Invalid address magnitude");
        Number = number; BitWidth = width;
        if (width == 32)
            Text = string.Join('.', Enumerable.Range(0, 4).Select(i => ((number >> (24 - 8 * i)) & 255).ToString(CultureInfo.InvariantCulture)));
        else
        {
            var groups = Enumerable.Range(0, 8).Select(i => (int)((number >> (112 - 16 * i)) & 65535)).ToArray();
            var best = -1; var length = 1;
            for (var i = 0; i < groups.Length;)
            {
                if (groups[i] != 0) { i++; continue; }
                var start = i; while (i < groups.Length && groups[i] == 0) i++;
                if (i - start > length) { best = start; length = i - start; }
            }
            string Join(IEnumerable<int> values) => string.Join(':', values.Select(v => v.ToString("x", CultureInfo.InvariantCulture)));
            Text = best < 0 ? Join(groups) : Join(groups.Take(best)) + "::" + Join(groups.Skip(best + length));
        }
    }
    internal static IpAddressValue Parse(string text)
    {
        if (text.Length is < 2 or > 64 || text.Any(c => !char.IsAsciiHexDigit(c) && c is not (':' or '.')))
            throw new FormatException("Expected an unscoped numeric IPv4/IPv6 address");
        if (!text.Contains(':'))
        {
            var parts = text.Split('.'); if (parts.Length != 4) throw new FormatException("IPv4 requires four decimal octets");
            BigInteger value = 0;
            foreach (var part in parts)
            {
                if (part.Length is < 1 or > 3 || part.Any(c => !char.IsAsciiDigit(c)) || part.Length > 1 && part[0] == '0' ||
                    !int.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out var octet) || octet > 255)
                    throw new FormatException("IPv4 octets must be 0–255 without leading zeroes");
                value = value * 256 + octet;
            }
            return new(value, 32);
        }
        if (text.Contains('.')) _ = Parse(text[(text.LastIndexOf(':') + 1)..]); // Keep embedded IPv4 equally strict.
        if (!IPAddress.TryParse(text, out var address) || address.GetAddressBytes().Length != 16)
            throw new FormatException("Invalid IPv6 literal");
        return new(new BigInteger(address.GetAddressBytes(), isUnsigned: true, isBigEndian: true), 128);
    }
    public override string ToString() => Text;
}
