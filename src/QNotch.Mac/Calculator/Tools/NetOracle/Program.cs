// .NET oracle for the Swift engine's BigInt and .NET number helpers (Sources/CalculatorEngine/Support).
// Dev tool, never shipped. Regenerate the committed vectors from the repository root with:
//   dotnet run -c Release --project src/QNotch.Mac/Calculator/Tools/NetOracle -- \
//     src/QNotch.Mac/Calculator/Tests/CalculatorEngineTests/Vectors/DotNetOracle.txt [verbose.txt]
// The optional second file lists every result uncompacted, for diffing a failing case by index.
//
// Inputs are edge values plus splitmix64-generated cases that Tests/CalculatorEngineTests/OracleVectors.swift
// regenerates identically, so random cases store only an FNV-1a hash of their results. Edge sections are
// readable: one line per input, results separated by tabs, any result longer than 40 characters replaced by
// "#" + its hash.
using System.Globalization;
using System.Numerics;
using System.Text;

var I = CultureInfo.InvariantCulture;
var output = new StringBuilder();
var verbose = args.Length > 1 ? new StringBuilder() : null;
output.Append("# .NET ").Append(Environment.Version).Append(" oracle vectors from Tools/NetOracle; regenerate, do not edit.\n");

// ---- BigInteger ----

BigInteger P2(int n) => BigInteger.One << n;
BigInteger[] edges =
[
    0, 1, -1, 2, -2, 7, -7, 10, 127, 128, -128, -129, 255, 256, -256, int.MaxValue, int.MinValue, uint.MaxValue,
    P2(32), -P2(32), long.MaxValue, long.MinValue, (BigInteger)long.MinValue - 1, P2(63), ulong.MaxValue, P2(64),
    P2(64) + 1, -P2(64), -P2(64) - 1, -(P2(64) - 1), P2(53), P2(53) + 1, P2(53) + 3, -(P2(53) + 3), P2(128),
    P2(128) - 1, -P2(128), P2(1023), P2(1024) - 1, P2(1024), -P2(1024), BigInteger.Pow(10, 19),
    BigInteger.Pow(10, 38), BigInteger.Pow(10, 100), 1 - BigInteger.Pow(10, 100), P2(4096) - 1, -P2(4095),
];

BigInteger Truncate(BigInteger value, int bits) => value >> Math.Max(0, (int)value.GetBitLength() - bits);

List<string> Unary(BigInteger a, int shift, int hexWidth, int powExponent) =>
[
    a.ToString(I), (-a).ToString(I), BigInteger.Abs(a).ToString(I), (~a).ToString(I), a.Sign.ToString(I),
    B(a.IsZero), B(a.IsOne), B(a.IsEven), a.GetBitLength().ToString(I), a.GetByteCount().ToString(I),
    a.Sign >= 0 ? a.GetByteCount(true).ToString(I) : "-", BigInteger.TrailingZeroCount(a).ToString(I),
    a.ToString("X", I), a.ToString("x", I), a.ToString("X" + hexWidth.ToString(I), I),
    (a << shift).ToString(I), (a >> shift).ToString(I), D((double)a), D(BigInteger.Log(a)), D(BigInteger.Log10(a)),
    a >= long.MinValue && a <= long.MaxValue ? ((long)a).ToString(I) : "overflow", BigInteger.Pow(a, powExponent).ToString(I),
];

List<string> Binary(BigInteger a, BigInteger b, BigInteger exponent, BigInteger modulus)
{
    var results = new List<string> { (a + b).ToString(I), (a - b).ToString(I), (a * b).ToString(I) };
    if (b.IsZero) results.AddRange(["-", "-"]);
    else { var q = BigInteger.DivRem(a, b, out var r); results.AddRange([q.ToString(I), r.ToString(I)]); }
    results.AddRange([BigInteger.GreatestCommonDivisor(a, b).ToString(I), (a & b).ToString(I), (a | b).ToString(I),
        (a ^ b).ToString(I), a.CompareTo(b).ToString(I), B(a == b),
        modulus.IsZero ? "-" : BigInteger.ModPow(a, exponent, modulus).ToString(I)]);
    return results;
}

BigInteger RandomBig(Rng r)
{
    var kind = r.Next() % 16;
    if (kind == 0) return edges[(int)(r.Next() % (ulong)edges.Length)];
    int bits;
    if (kind <= 4) bits = (int)(r.Next() % 65);
    else if (kind <= 13) bits = (int)(r.Next() % ((1UL << (int)(r.Next() % 13)) + 1));
    else bits = 4096 + (int)(r.Next() % 1000);
    BigInteger magnitude;
    switch (r.Next() % 8)
    {
        case 0: magnitude = P2(bits) - 1; break;
        case 1: magnitude = P2(bits); break;
        case 2: magnitude = P2(bits) + (int)(r.Next() % 3) - 1; break;
        default:
            var bytes = new byte[((bits + 63) / 64) * 8];
            for (var i = 0; i < bytes.Length; i += 8) BitConverter.TryWriteBytes(bytes.AsSpan(i), r.Next());
            magnitude = new BigInteger(bytes, isUnsigned: true) & (P2(bits) - 1);
            break;
    }
    return (r.Next() & 1) == 1 ? -magnitude : magnitude;
}

Section("bigint-edge-unary");
foreach (var a in edges) Line(Unary(a, 5, 24, 3)); // fixed shift/width/power keep these lines readable
foreach (var a in edges) Line(Unary(a, -70, 0, 0));
Section("bigint-edge-binary");
foreach (var a in edges) foreach (var b in edges) HashLine(Binary(a, b, Truncate(BigInteger.Abs(a), 160), Truncate(b, 1100)));
Section("bigint-random");
{
    var r = new Rng(0x51A7_C0DE_0001);
    for (var i = 0; i < 2500; i++)
    {
        BigInteger a = RandomBig(r), b = RandomBig(r), c = RandomBig(r);
        int shift = (int)(r.Next() % 401) - 200, hexWidth = (int)(r.Next() % 40);
        int power = (int)(r.Next() % (a.GetBitLength() <= 64 ? 40UL : 4UL));
        HashLine([.. Unary(a, shift, hexWidth, power), .. Binary(a, b, Truncate(BigInteger.Abs(b), 160), Truncate(c, 1100))]);
    }
}
Section("bigint-parse");
foreach (var text in new[] { "0", "-0", "+0", "+17", "-17", "007", "-0009223372036854775808", "9223372036854775808",
    "123456789012345678901234567890", "-99999999999999999999", "1" + new string('0', 400), "", "-", "+", " 1", "1 ", "1_0",
    "0x10", "1e3", "--1", "+-1", "١٢", "12a" })
    Line([text, BigInteger.TryParse(text, NumberStyles.AllowLeadingSign, I, out var parsed) ? parsed.ToString(I) : "invalid"]);

// ---- Double formatting and Math.Round ----

string[] doubleFormats = ["", "R", "G", "G1", "G2", "G3", "G4", "G6", "G15", "G17", "E", "E0", "E1", "E3", "E10", "E15",
    "N", "N0", "N1", "N3", "F", "F0", "F1", "F2", "F4", "F10", "0.##", "0.###", "0.00", "0.0", "0.#E+0", "00", "0", "e3", "g5", "r"];
double[] tens = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22];
double[] edgeDoubles = [0.0, -0.0, 1, -1, 0.1, 0.125, 0.375, 0.5, 1.5, 2.5, -2.5, 2.675, 1.005, 4.35, 1.25, 1.35, 0.0625,
    9.5, 8.5, 12345.5, 123.456, 1e15, 1e16, 1e17, 1e20, 1e21, 1e23, 1.5e-5, 0.0001, 0.00001, 5e-324, double.MaxValue,
    -double.MaxValue, 2.2250738585072014E-308, double.NaN, double.PositiveInfinity, double.NegativeInfinity, -0.001, -0.004,
    -0.4, 0.6, 0.06, 0.96, 0.005, 0.015, 1234567890123445, 1234567890123455, 0.1 + 0.2, 1 / 3.0, 2 / 3.0, 100, 1e-7, 9.995,
    0.995, 999999.5, 0.49999999999999994, 4503599627370497, 9007199254740992, 1e16 + 2, 123456789.125, -1e-10, 7e22, 1e22];

double RandomDouble(Rng r)
{
    double value;
    switch (r.Next() % 8)
    {
        case 0: value = edgeDoubles[(int)(r.Next() % (ulong)edgeDoubles.Length)]; break;
        case 1: value = BitConverter.UInt64BitsToDouble(r.Next()); break;
        case 2: value = ((long)(r.Next() % 2000001) - 1000000) / tens[(int)(r.Next() % 12)]; break;
        case 3: value = (2 * (long)(r.Next() % 100000) + 1) / (double)(1L << (int)(r.Next() % 10 + 1)); break;
        case 4: value = (double)(long)(r.Next() >> (int)(r.Next() % 64)); break;
        case 5: { var mantissa = (r.Next() >> 11) * (1.0 / (1UL << 53)); var e = (int)(r.Next() % 45); value = e < 22 ? mantissa / tens[22 - e] : mantissa * tens[e - 22]; break; }
        case 6: value = ((long)(r.Next() % 100000) + 0.5) / tens[(int)(r.Next() % 6)]; break;
        default: value = BitConverter.UInt64BitsToDouble(r.Next() % (1UL << 53)); break;
    }
    return (r.Next() & 1) == 1 ? -value : value;
}

List<string> DoubleResults(double x, int digits)
{
    var results = doubleFormats.Select(f => x.ToString(f, I)).ToList();
    results.AddRange([D(Math.Round(x)), D(Math.Round(x, MidpointRounding.AwayFromZero)), D(Math.Round(x, digits)),
        D(Math.Round(x, digits, MidpointRounding.AwayFromZero)), double.IsFinite(x) ? new BigInteger(x).ToString(I) : "overflow"]);
    return results;
}

Section("double-edge");
foreach (var x in edgeDoubles) Line([D(x), .. DoubleResults(x, 2)]);
Section("double-random");
{
    var r = new Rng(0x51A7_C0DE_0002);
    for (var i = 0; i < 4000; i++) { var x = RandomDouble(r); HashLine([D(x), .. DoubleResults(x, (int)(r.Next() % 16))]); }
}

// ---- Int64 formatting ----

string[] longFormats = ["", "D", "D1", "D3", "D5", "D19", "D25", "X", "X2", "X4", "x", "x8", "X16", "X20", "N0", "N", "N2", "00", "0", "000", "0.00", "0.#"];
long[] edgeLongs = [0, 1, -1, 5, -5, 9, 10, 99, 100, 999, 1000, -1000, 1234567, -1234567, 65535, 65536, int.MaxValue, int.MinValue, long.MaxValue, long.MinValue];
List<string> LongResults(long value) => [.. longFormats.Select(f => value.ToString(f, I))];
Section("long-edge");
foreach (var value in edgeLongs) Line([value.ToString(I), .. LongResults(value)]);
Section("long-random");
{
    var r = new Rng(0x51A7_C0DE_0003);
    for (var i = 0; i < 1500; i++)
    {
        var value = (long)(r.Next() >> (int)(r.Next() % 64));
        if ((r.Next() & 1) == 1) value = -value;
        HashLine([value.ToString(I), .. LongResults(value)]);
    }
}

File.WriteAllText(args[0], output.ToString());
if (verbose is not null) File.WriteAllText(args[1], verbose.ToString());
Console.WriteLine("Wrote " + output.Length + " bytes to " + args[0]);

static string B(bool value) => value ? "true" : "false";
static string D(double value) => double.IsNaN(value) ? "NaN" : BitConverter.DoubleToUInt64Bits(value).ToString("x16", CultureInfo.InvariantCulture);
static string Compact(string value) => value.Length > 40 ? "#" + Fnv(value).ToString("x16", CultureInfo.InvariantCulture) : value;
static ulong Fnv(string value)
{
    var hash = 0xcbf29ce484222325UL;
    foreach (var b in Encoding.UTF8.GetBytes(value)) { hash ^= b; hash *= 0x100000001b3UL; }
    return hash;
}

void Section(string name) { output.Append('@').Append(name).Append('\n'); verbose?.Append('@').Append(name).Append('\n'); }
void Line(List<string> results)
{
    output.Append(string.Join('\t', results.Select(Compact))).Append('\n');
    verbose?.Append(string.Join('\t', results)).Append('\n');
}
void HashLine(List<string> results)
{
    output.Append(Fnv(string.Join('\n', results)).ToString("x16", I)).Append('\n');
    verbose?.Append(string.Join('\t', results)).Append('\n');
}

/// splitmix64, mirrored by the Swift tests.
sealed class Rng(ulong seed)
{
    private ulong state = seed;
    public ulong Next()
    {
        state += 0x9E3779B97F4A7C15UL;
        var z = state;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
        return z ^ (z >> 31);
    }
}
