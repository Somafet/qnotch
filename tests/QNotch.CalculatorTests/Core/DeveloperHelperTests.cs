using System.Text;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class DeveloperHelperTests
{
    private static SheetValue Last(string source)
    { var result = SheetEvaluator.Evaluate(source)[^1]; Assert.Null(result.Error); Assert.NotNull(result.Value); return result.Value.Value; }
    public static IEnumerable<object[]> OracleCases()
    {
        using var stream = typeof(DeveloperHelperTests).Assembly.GetManifestResourceStream("Calc.DeveloperOracle")!;
        using var doc = JsonDocument.Parse(stream);
        return doc.RootElement.GetProperty("cases").EnumerateArray().Select(row => new object[] { row.GetRawText() }).ToArray();
    }
    [Theory, MemberData(nameof(OracleCases))]
    public void IndependentStandardLibraryOracle(string json)
    {
        using var doc = JsonDocument.Parse(json); var row = doc.RootElement; var value = Last(row.GetProperty("source").GetString()!);
        switch (row.GetProperty("kind").GetString())
        {
            case "permission":
                Assert.Equal(row.GetProperty("bits").GetInt32(), value.Permission.Bits);
                Assert.Equal(row.GetProperty("symbolic").GetString(), value.Permission.Symbolic);
                Assert.Equal(value.Permission.Bits, Last("chmod(\"" + value.Permission.Symbolic + "\")").Permission.Bits);
                break;
            case "colour":
                var rgb = row.GetProperty("rgb").EnumerateArray().Select(v => v.GetInt32()).ToArray();
                Assert.Equal(new Rational(rgb[0],255), value.Colour.Red); Assert.Equal(new Rational(rgb[1],255), value.Colour.Green); Assert.Equal(new Rational(rgb[2],255), value.Colour.Blue);
                var hsl = row.GetProperty("hsl").EnumerateArray().Select(v => v.GetDouble()).ToArray();
                static double Double(Rational r) => (double)r.Numerator / (double)r.Denominator;
                Assert.InRange(Math.Abs(Double(value.Colour.Hue)-hsl[0]),0,1e-10);
                Assert.InRange(Math.Abs(Double(value.Colour.Saturation)-hsl[1]),0,1e-12);
                Assert.InRange(Math.Abs(Double(value.Colour.Lightness)-hsl[2]),0,1e-12);
                break;
            case "hsl":
                var expected = row.GetProperty("rgb").EnumerateArray().Select(v=>v.GetDouble()).ToArray();
                var channels = new[]{value.Colour.Red,value.Colour.Green,value.Colour.Blue};
                for(var i=0;i<3;i++) Assert.InRange(Math.Abs((double)channels[i].Numerator/(double)channels[i].Denominator-expected[i]),0,1e-12);
                break;
            case "aspect": Assert.Equal(new Rational(row.GetProperty("n").GetInt32(),row.GetProperty("d").GetInt32()), value.Aspect.Ratio); break;
            case "unicode":
                Assert.Equal(row.GetProperty("scalar").GetInt32(),Assert.Single(value.Unicode.Scalars));
                Assert.Equal(row.GetProperty("utf8").GetString(), Convert.ToHexStringLower(Encoding.UTF8.GetBytes(value.Unicode.Text)));
                Assert.Equal(row.GetProperty("utf16Units").GetInt32(),value.Unicode.Text.Length); break;
        }
        Assert.Equal(value, Last(value.CopyText));
    }
    [Theory]
    [InlineData("#FF8800 in rgb", "rgb(255, 136, 0)")]
    [InlineData("#FF8800 in hsl", "hsl(32, 100%, 50%)")]
    [InlineData("chmod 755", "rwxr-xr-x")]
    [InlineData("1920x1080 aspect", "16:9")]
    [InlineData("U+1F600", "😀 U+1F600")]
    [InlineData("hsl(-120,100%,50%) in hex", "#0000FF")]
    [InlineData("rgb(100%,0%,0%) in hex", "#FF0000")]
    [InlineData("#f008 in rgb", "rgba(255, 0, 0, 0.5333)")]
    [InlineData("chmod(\"rwsr-Sr-t\")", "7745")]
    [InlineData("aspect(192 cm,1.08 m)", "16:9")]
    [InlineData("(16/9) in ratio", "16:9")]
    [InlineData("unicode(\"e\\u0301\")", "U+0065 U+0301")]
    [InlineData("U=7\nU+1234", "1241")]
    [InlineData("a=#face\na in rgb", "rgba(255, 170, 204, 0.9333)")]
    public void PublishedExamplesAndConventions(string source,string expected) => Assert.Equal(expected, Last(source).Display);
    [Theory]
    [InlineData("rgb(-1,0,0)")][InlineData("rgb(256,0,0)")][InlineData("rgb(1,2,3,2)")]
    [InlineData("hsl(1,101,50)")][InlineData("hsl(1,50,-1)")][InlineData("hsl(50%,50,50)")]
    [InlineData("color(\"#12345\")")][InlineData("color(\"#GGG\")")][InlineData("rgb(1)")]
    [InlineData("chmod 888")][InlineData("chmod -1")][InlineData("chmod 10000")][InlineData("chmod u+x")]
    [InlineData("chmod(\"rwqrwxrwx\")")][InlineData("chmod(\"rwxrwxrws\")")][InlineData("chmod(0x1000)")]
    [InlineData("aspect(0,1)")][InlineData("aspect(-1,1)")][InlineData("aspect(1 m,2 s)")]
    [InlineData("aspect(1%,2%)")][InlineData("aspect(1 Celsius,2 Celsius)")][InlineData("50% in ratio")]
    [InlineData("U+D800")][InlineData("U+DFFF")][InlineData("U+110000")][InlineData("codepoint(-1)")]
    [InlineData("#fff in hex u8")][InlineData("codepoint(50%)")][InlineData("codepoint(0.5)")][InlineData("unicode(\"\")")][InlineData("unicode(1)")]
    [InlineData("#fff+1")][InlineData("chmod(755)+1")][InlineData("U+1F600+1")]
    public void InvalidDomainsAndTypedArithmeticFail(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);
    [Fact]
    public void TagsFunctionsReferencesAndExactCopies()
    {
        var lines = SheetEvaluator.Evaluate("# Heading\nc=#abc #palette\n2 #face\nc in hsl\nchmod(0o755)\nf(x)=rgb(x,0,0)\nf(128)");
        Assert.All(lines, line=>Assert.Null(line.Error)); Assert.Equal("2",Last("2 #face\nsum #face").Display);
        Assert.Equal(493,lines[4].Value!.Value.Permission.Bits);
        Assert.Equal(new Rational(128,255),lines[^1].Value!.Value.Colour.Red);
        var quantized=Last("rgb(0.5,0,0) in hex"); Assert.StartsWith("≈",quantized.Display);
        Assert.Equal("colour hex presentation",SheetEvaluator.Evaluate("rgb(0.5,0,0) in hex")[0].Explanation[^1].Operation); Assert.Equal(quantized, Last(quantized.CopyText));
        Assert.Equal(Last("rgb(0.5,0,0)"),Last("rgb("+quantized.CopyText+")"));
        Assert.Equal(Last("U+0000"),Last(Last("U+0000").CopyText));
        Assert.Equal(0,Last("chr(0)").Text.Value[0]);
    }
    [Fact]
    public void SequenceBoundAndCancellation()
    {
        Assert.Equal(256,Last("unicode(text(\""+new string('a',256)+"\"))").Unicode.Scalars.Count);
        Assert.NotNull(SheetEvaluator.Evaluate("unicode(text(\""+new string('a',257)+"\"))")[0].Error);
        using var cancel=new CancellationTokenSource();cancel.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(()=>SheetEvaluator.Evaluate("#fff in rgb",cancellationToken:cancel.Token));
    }
}
