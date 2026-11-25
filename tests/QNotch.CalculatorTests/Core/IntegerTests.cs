using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class IntegerTests
{
    private static SheetValue Last(string source)
    {
        var result = SheetEvaluator.Evaluate(source)[^1]; Assert.Null(result.Error); Assert.NotNull(result.Value); return result.Value.Value;
    }
    public static IEnumerable<object[]> OracleCases()
    {
        using var stream = typeof(IntegerTests).Assembly.GetManifestResourceStream("Calc.IntegerOracle")!;
        using var json = JsonDocument.Parse(stream);
        return json.RootElement.GetProperty("cases").EnumerateArray().Select(row => new object[] { row.GetRawText() }).ToArray();
    }
    [Theory, MemberData(nameof(OracleCases))]
    public void IndependentBitListOracle(string json)
    {
        using var parsed = JsonDocument.Parse(json); var row = parsed.RootElement;
        var value = Last(row.GetProperty("source").GetString()!).Integer;
        Assert.Equal(BigInteger.Parse(row.GetProperty("value").GetString()!), value.Value);
        Assert.Equal(row.GetProperty("width").GetInt32(), value.Width); Assert.Equal(row.GetProperty("signed").GetBoolean(), value.Signed);
        var copied = Last(value.CopyText).Integer;
        Assert.Equal(value.Value, copied.Value); Assert.Equal(value.Width, copied.Width); Assert.Equal(value.Signed, copied.Signed); Assert.Equal(value.FullText, copied.FullText);
    }
    [Theory]
    [InlineData("255 in hex", "0xFF")]
    [InlineData("10 in binary", "0b1010")]
    [InlineData("255 in bin 8 bits", "0b11111111")]
    [InlineData("-1 in hex u8", "0xFF")]
    [InlineData("300 in u8", "44")]
    [InlineData("0xF0 & 0x3C", "0x30")]
    [InlineData("1 << 4", "16")]
    [InlineData("0xFF in i8", "-1")]
    [InlineData("-1 in hex", "-0x1")]
    [InlineData("0o17 + 0b1", "0o20")]
    [InlineData("0xF_F + 1", "0x100")]
    [InlineData("(255 in u8)+1", "0")]
    [InlineData("(127 in i8)+1", "-128")]
    [InlineData("(1 in u8)-2", "255")]
    [InlineData("(0x81 in i8) >> 1", "-64")]
    [InlineData("(0x81 in i8) >>> 1", "64")]
    [InlineData("~0xF0", "-0xF1")]
    [InlineData("(0xF0 in hex u8) & 0x3C", "0x30")]
    [InlineData("1|2", "3")]
    [InlineData("1 | 2 xor 3 & 4 << 1 + 1", "3")]
    [InlineData("2^3", "8")]
    [InlineData("0x2^3", "0x8")]
    [InlineData("100+10%", "110")]
    [InlineData("(3 in u8)/2", "1.5")]
    [InlineData("(4 in u8)/2", "2")]
    [InlineData("(3 in u8)^-1", "1/3")]
    [InlineData("(3 in u8)+0.5", "3.5")]
    [InlineData("(3 in u8)*2 m", "6 m")]
    [InlineData("abs(-0x20)", "32")]
    [InlineData("bitand(0xF0,0x3C)", "0x30")]
    [InlineData("bitnot(uint(0,8))", "255")]
    [InlineData("mask=0xF0\ninput=0x3C\nmask & input", "0x30")]
    [InlineData("flag 0xFF", "0xFF")]
    [InlineData("x=0xFF\nsum", "255")]
    public void PublishedExamplesAndContracts(string source, string display) => Assert.Equal(display, Last(source).Display);

    [Theory]
    [InlineData("0x")][InlineData("0b2")][InlineData("0o8")][InlineData("0xGG")][InlineData("0x_F")][InlineData("0xF_")][InlineData("0xF__F")]
    [InlineData("1 in u0")][InlineData("1 in i4097")][InlineData("1 in bin 0 bits")][InlineData("1 in hex 1.5 bits")]
    [InlineData("1 << -1")][InlineData("1 >> 4097")][InlineData("-1 >>> 1")][InlineData("1 & 1.5")][InlineData("2% | 1")][InlineData("2 m & 1")]
    [InlineData("uint(1.5,8)")][InlineData("hex(2%)")][InlineData("hex(sqrt(2))")][InlineData("uint(1,1.5)")]
    [InlineData("(1 in u8)+(1 in i8)")][InlineData("(1 in u8)&(1 in u16)")]
    [InlineData("hex(1,2)")][InlineData("bitand(1)")][InlineData("uint(1)")][InlineData("sint(1,8,3)")]
    public void InvalidInputsAreErrors(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);

    [Fact]
    public void MaximumWordsKeepCompleteCopyAndBoundedDisplay()
    {
        var value = Last("-1 in bin u4096").Integer;
        Assert.Equal(4098, value.FullText.Length); Assert.True(value.Display.Length < 128); Assert.Contains('…', value.Display);
        Assert.Equal(value, Last(value.CopyText).Integer);
        Assert.Equal(BigInteger.One << 4095, Last("1 << 4095").Integer.Value);
        Assert.NotNull(SheetEvaluator.Evaluate("1 << 4096")[0].Error);
        Assert.NotNull(SheetEvaluator.Evaluate("0x1" + new string('0', 1024))[0].Error);
        Assert.Equal(BigInteger.Zero, Last("(-1 in u4096) << 4096").Integer.Value);
        Assert.Equal(-BigInteger.One, Last("(-1 in i4096) >> 4096").Integer.Value);
        Assert.Equal(BigInteger.Zero, Last("(-1 in i4096) >>> 4096").Integer.Value);
    }
    [Fact]
    public void FunctionsPreserveWordProfilesAndRejectBadArityAtDeclaration()
    {
        var library = new FunctionLibrary([new("mask", ["x"], "(x in hex u8) & 0xF0"), new("wrap", ["x"], "uint(x,8)+1")]);
        Assert.Equal("0xF0", new SheetEvaluationSession().EvaluateWithFunctions("mask(-1)", library, []).Results[0].Display);
        Assert.Equal("0", new SheetEvaluationSession().EvaluateWithFunctions("wrap(255)", library, []).Results[0].Display);
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("bad", [], "uint(1)")]));
    }
    [Fact]
    public void CancellationAndBudgetRemainShared()
    {
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("1 << 4095", cancellationToken: cancellation.Token));
        var source = string.Join('+', Enumerable.Repeat("uint(-1,4096)", 1000));
        Assert.NotNull(SheetEvaluator.Evaluate(source)[0].Error);
    }
}
