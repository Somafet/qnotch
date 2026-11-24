using System.Text;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class TextCodecTests
{
    private static LineResult Last(string source)
    { var result = SheetEvaluator.Evaluate(source)[^1]; Assert.Null(result.Error); Assert.NotNull(result.Value); return result; }
    public static IEnumerable<object[]> OracleCases()
    {
        using var stream = typeof(TextCodecTests).Assembly.GetManifestResourceStream("Calc.TextOracle")!;
        using var doc = JsonDocument.Parse(stream);
        return doc.RootElement.GetProperty("cases").EnumerateArray().Select(row => new object[] { row.GetRawText() }).ToArray();
    }
    [Theory, MemberData(nameof(OracleCases))]
    public void IndependentByteCodecAndDigestOracle(string json)
    {
        using var parsed = JsonDocument.Parse(json); var row = parsed.RootElement;
        var result = Last(row.GetProperty("source").GetString()!); var value = result.Value!.Value;
        var expected = row.GetProperty("output").GetString()!;
        Assert.Equal(expected, value.Text.Value); Assert.Equal(expected.Contains('\0') ? value.Text.ExpressionText : expected, value.CopyText);
        Assert.Equal(expected, Last(value.Text.ExpressionText).Value!.Value.Text.Value);
        var evidence = result.Explanation.Last(step => step.TextTransform is not null).TextTransform!;
        var bytes = Convert.FromHexString(row.GetProperty("inputUtf8").GetString()!);
        Assert.Equal(bytes.Length, evidence.InputUtf8Bytes); Assert.Equal(Encoding.UTF8.GetByteCount(expected), evidence.OutputUtf8Bytes);
        Assert.Equal(row.GetProperty("input").GetString(), evidence.Input); Assert.Equal(expected, evidence.Output);
        Assert.Equal(Convert.ToHexStringLower(bytes.AsSpan(0, Math.Min(32, bytes.Length))) + (bytes.Length > 32 ? "…" : ""), evidence.InputBytePreview);
    }
    [Theory]
    [InlineData("base64 \"hello\"", "aGVsbG8=")]
    [InlineData("base64 hello", "aGVsbG8=")]
    [InlineData("decode base64 aGVsbG8=", "hello")]
    [InlineData("urlencode \"a b&c\"", "a%20b%26c")]
    [InlineData("md5 abc", "900150983cd24fb0d6963f7d28e17f72")]
    [InlineData("sha256 \"abc\"", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")]
    [InlineData("sha1 abc", "a9993e364706816aba3e25717850c26c9cd0d89d")]
    [InlineData("decode base64 YT1iI2MgLy9k", "a=b#c //d")]
    [InlineData("urlencode https://example.test/a//b?x=1&y=two words#part", "https%3A%2F%2Fexample.test%2Fa%2F%2Fb%3Fx%3D1%26y%3Dtwo%20words%23part")]
    [InlineData("urldecode a+b%20c%2fd%23x", "a+b c/d#x")]
    [InlineData("x=base64 hello\ndecodeBase64(x)", "hello")]
    [InlineData("base64 \"hello\" #demo // note", "aGVsbG8=")]
    [InlineData("x=text(\"a=b #t //comment\")\nx", "a=b #t //comment")]
    [InlineData("text(\"+\")", "+")][InlineData("text(\"-\")", "-")][InlineData("text(\"in\")", "in")]
    [InlineData("text(\"until\")", "until")][InlineData("text(\"is\")", "is")][InlineData("text(\"at\")", "at")]
    [InlineData("text(\"\\uD83D\\uDE00\")", "😀")][InlineData("text(\"\\u0000\")", "\0")]
    [InlineData("text(\"  space  \\n\")", "  space  \n")]
    public void PublishedCommandsAndLiteralPreservation(string source, string expected) => Assert.Equal(expected, Last(source).Value!.Value.Text.Value);
    [Theory]
    [InlineData("\"label #tag // =\" 2+2", "4")]
    [InlineData("2 \"unrecognized \\q escape remains a comment\" +2", "4")]
    [InlineData("sqrt(\"note\" 4)", "2")]
    [InlineData("base64=7\nbase64+1", "8")]
    [InlineData("x=2\n\"md5 abc\" x+2", "4")]
    public void QuotedCommentsAndOrdinaryNamesRemainCompatible(string source, string expected) => Assert.Equal(expected, Last(source).Display);
    [Theory]
    [InlineData("decode base64 Zg")][InlineData("decode base64 Zh==")][InlineData("decode base64 Zg===")]
    [InlineData("decodeBase64(\"Z g==\")")][InlineData("decodeBase64(\"_w==\")")][InlineData("decodeBase64(\"/w==\")")]
    [InlineData("urldecode %")][InlineData("urldecode %1")][InlineData("urldecode %GG")][InlineData("urldecode %FF")][InlineData("urldecode %C0%AF")]
    [InlineData("text(\"\\uD800\")")][InlineData("text(\"\\uDC00\")")][InlineData("text(\"\\uD800x\")")][InlineData("text(\"\\q\")")]
    [InlineData("text(\"unterminated)")][InlineData("text()")][InlineData("base64(1)")][InlineData("sha256(1 USD)")][InlineData("md5(\"a\",\"b\")")]
    [InlineData("text(\"2\")+1")][InlineData("text(\"2\")&1")][InlineData("base64(missing)")]
    public void MalformedBytesTypesAndLiteralsAreErrors(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);
    [Fact]
    public void DataCaseSurvivesDefinitionIdentityReceiptsAndCaching()
    {
        var first = FunctionUpdate.Prepare("digest()=md5(\"a\")", FunctionLibrary.Empty, []);
        var changed = FunctionUpdate.Prepare("digest()=md5(\"A\")", first.Library, first.Receipts);
        Assert.NotEqual(first.Library.Fingerprint, changed.Library.Fingerprint); Assert.True(changed.HasChanges);
        var session = new SheetEvaluationSession();
        Assert.Equal("0cc175b9c0f1b6a831c399e269772661", session.EvaluateWithFunctions("digest()", first.Library, []).Results[0].Display);
        Assert.Equal("7fc56270e7a70fa81a5935b72eacbe29", session.EvaluateWithFunctions("digest()", changed.Library, []).Results[0].Display);
        var library = new FunctionLibrary([new("enc", ["x"], "base64(x)"), new("natural", [], "base64 hello")]);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("enc(text(\"hello\"))\nnatural()", library, []).Results;
        Assert.All(results, result => Assert.Equal("aGVsbG8=", result.Display));
    }
    [Theory]
    [InlineData("digest()=base64 \"\\uD800\"\ndigest()")]
    [InlineData("digest()=sha256(\"\\uD800\")\ndigest()")]
    public void InvalidLiteralDefinitionsBlockEarlierSavedFunctions(string source)
    {
        var library = new FunctionLibrary([new("digest", [], "md5(\"a\")")]);
        var results = new SheetEvaluationSession().EvaluateWithFunctions(source,library,[]).Results;
        Assert.NotNull(results[0].Error); Assert.NotNull(results[1].Error); Assert.Null(results[1].Value);
    }
    [Fact]
    public void CanonicalEscapesHaveTheSameIdentityWithoutNormalizingUnicode()
    {
        var a = new FunctionLibrary([new("v", [], "text(\"a\")")]); var escaped = new FunctionLibrary([new("v", [], "text(\"\\u0061\")")]);
        Assert.Equal(a.Fingerprint, escaped.Fingerprint);
        var composed = Last("sha256(\"é\")").Value!.Value.Text.Value; var decomposed = Last("sha256(\"e\\u0301\")").Value!.Value.Text.Value;
        Assert.NotEqual(composed, decomposed);
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("bad", [], "md5()") ]));
    }
    [Fact]
    public void FullCopiesAndEscapedPreviewsRemainDistinctAndBounded()
    {
        var payload = string.Concat(Enumerable.Repeat("😀", 16384));
        var expression = "text(" + JsonSerializer.Serialize(payload) + ")";
        var value = Last(expression).Value!.Value;
        Assert.Equal(payload, value.CopyText); Assert.True(value.Display.Length <= 128); Assert.Contains('…', value.Display);
        Assert.Equal(payload, Last(value.Text.ExpressionText).Value!.Value.Text.Value);
        Assert.Equal("\\n\\u0000", Last("text(\"\\n\\u0000\")").Display);
        Assert.NotNull(SheetEvaluator.Evaluate("urlencode(" + JsonSerializer.Serialize(payload) + ")")[0].Error);
        Assert.NotNull(SheetEvaluator.Evaluate("base64(" + JsonSerializer.Serialize(payload) + ")")[0].Error);
        Assert.Throws<ArithmeticException>(() => new TextValue(new string('x',32769)));
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate(expression,cancellation.Token));
    }
}
