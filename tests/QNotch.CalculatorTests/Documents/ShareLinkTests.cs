using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Calc.Core;
using Calc.Documents;

namespace Calc.Documents.Tests;

public sealed class ShareLinkTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "Calc-tests", Guid.NewGuid().ToString("N"));
    private static readonly Uri Viewer = new("https://viewer.example.test/calc/index.html");

    private static string FixturePath() => Path.Combine(AppContext.BaseDirectory, "fixtures", "share-links-v1.json");
    private static JsonElement Fixture() => JsonDocument.Parse(File.ReadAllText(FixturePath())).RootElement.Clone();

    // Built by hand to match the fixture's hand-written canonical text; independent of evaluator formatting.
    private static ShareSnapshot Golden(string name) => name switch
    {
        "starter" => new("Budget", ShareTheme.Light, new DateOnly(2026, 11, 1),
        [
            new("price = 120", "120"), new("discount = 15%", "15%"), new("price * discount", "18", Explanation: "multiply(120, 15%) = 18\nUses L1, L2"),
            new(""), new("# total"), new("1/0", "Division by zero", Error: true),
        ]),
        "unicode" => new("Ünïcode ✓ 😀", ShareTheme.Dark, null, [new("café = 3 € 😀 中文", "3"), new("\t indented  "), new("quote \" backslash \\ end", "\"q\"")]),
        "figures" => new("Figures", ShareTheme.Light, null,
        [
            new("Rent 1200 EUR", "1200 EUR"), new("Food 300 EUR", "300 EUR"),
            new("bar chart", "1500 EUR", Explanation: "Bar chart of 2 values, total 1500 EUR", Figure: new(ShareFigureKind.Bar, "Bar chart of 2 values, from Food 300 EUR to Rent 1200 EUR")
                { Total = "1500 EUR", Items = [new("Rent", 1200, "1200 EUR"), new("Food", 300, "300 EUR")] }),
            new("pie chart of [1, 3]", "4", Figure: new(ShareFigureKind.Pie, "Pie chart of 2 values, from 1 1 to 2 3") { Total = "4", Items = [new("1", 1, "1"), new("2", 3, "3")] }),
            new("trend chart of [1.5, -2, 0.25]", "3 points", Figure: new(ShareFigureKind.Trend, "Trend chart of 3 values, from 2 -2 to 1 1.5")
                { Items = [new("1", 1.5, "1.5"), new("2", -2, "-2"), new("3", 0.25, "0.25")] }),
            new("plot 1/x from -2 to 2", "plot", Explanation: "Formula: 1/x", Figure: new(ShareFigureKind.Plot, "Plot of 1/x for x from -2 to 2, y shown from [-10, 10]")
                { Frame = ["-2", "2", "-10", "10"], Points = [(0, 1843), (2047, -4096), (2049, 8192), (4096, 2253)], Segments = [0, 2] }),
        ]),
        "hostile" => new("<b>x</b>", ShareTheme.Light, null,
        [
            new("<script>alert(1)</script>"), new("<img src=x onerror=alert(1)> = 2", "<i>2</i>", Explanation: "</div><script>alert(2)</script>"),
            new("# javascript:alert(1) and https://example.test/a?b=1&c=<2>. done"), new("# data:text/html,<script>x</script> https://user:pw@example.test/"),
        ]),
        _ => throw new ArgumentOutOfRangeException(nameof(name)),
    };
    private static string Canonical(ShareSnapshot snapshot) => Encoding.UTF8.GetString(ShareLink.Serialize(snapshot));
    public static IEnumerable<object[]> Cases() => Fixture().GetProperty("cases").EnumerateArray().Select(item => new object[] { item.GetProperty("name").GetString()! });
    public static IEnumerable<object[]> Invalid() => Fixture().GetProperty("invalid").EnumerateArray()
        .Select(item => new object[] { item.GetProperty("name").GetString()!, item.GetProperty("fragment").GetString()!, item.GetProperty("error").GetString()! });

    [Theory, MemberData(nameof(Cases))]
    public void SerializationMatchesHandWrittenCanonicalPayload(string name)
    {
        var expected = Fixture().GetProperty("cases").EnumerateArray().Single(item => item.GetProperty("name").GetString() == name).GetProperty("payload").GetString();
        Assert.Equal(expected, Canonical(Golden(name)));
        Assert.Equal(ShareLink.Serialize(Golden(name)), ShareLink.Serialize(Golden(name)));
    }

    [Theory, MemberData(nameof(Cases))]
    public void DecodesFragmentsCompressedByNodeAndByDotnet(string name)
    {
        var item = Fixture().GetProperty("cases").EnumerateArray().Single(entry => entry.GetProperty("name").GetString() == name);
        var payload = item.GetProperty("payload").GetString();
        Assert.Equal(payload, Canonical(ShareLink.Decode(item.GetProperty("node").GetString()!)));
        var recorded = item.GetProperty("dotnet").GetString();
        Assert.False(string.IsNullOrEmpty(recorded), "Record .NET fragments: set CALC_WRITE_SHARE_FIXTURES=1 and run this test once");
        Assert.Equal(payload, Canonical(ShareLink.Decode(recorded!)));
        Assert.Equal(payload, Canonical(ShareLink.Decode("#" + ShareLink.EncodeFragment(Golden(name)))));
    }

    // The browser decoder reads these .NET-compressed fragments too (tests/repository/share-viewer.test.mjs).
    [Fact]
    public void RecordsDotnetFragmentsOnRequest()
    {
        if (Environment.GetEnvironmentVariable("CALC_WRITE_SHARE_FIXTURES") != "1") return;
        var path = FixturePath();
        var root = JsonNode.Parse(File.ReadAllText(path))!;
        foreach (var item in root["cases"]!.AsArray()) item!["dotnet"] = ShareLink.EncodeFragment(Golden(item["name"]!.GetValue<string>()));
        File.WriteAllText(path, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true, IndentSize = 1, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }).Replace("\r\n", "\n") + "\n");
    }

    [Theory, MemberData(nameof(Invalid))]
    public void RejectsHostileFragmentsWithTheBrowserDecodersMessage(string name, string fragment, string error)
    {
        var failure = Assert.Throws<ShareLinkException>(() => ShareLink.Decode(fragment));
        Assert.True(error == failure.Message, $"{name}: {failure.Message}");
    }

    [Fact]
    public void RejectsOversizedFragmentsBeforeDecoding()
    {
        Assert.Equal("Link too large", Assert.Throws<ShareLinkException>(() => ShareLink.Decode("c1." + new string('A', ShareLink.MaxFragmentCharacters - 2))).Message);
        Assert.Equal("Unsupported link version", Assert.Throws<ShareLinkException>(() => ShareLink.Decode("c1" + new string('A', 10))).Message);
    }

    [Fact]
    public void CapturesTheSheetAsComputedFromRealEvaluation()
    {
        var source = "price = 120\r\ndiscount = 15%\nprice * discount\n\n# note\n1/0\n\nRent 1200\nFood 300\nbar chart\nplot 1/x from -2 to 2";
        var results = SheetEvaluator.Evaluate(source);
        var snapshot = ShareLink.Capture("  ", source, results, dark: true, new DateOnly(2026, 11, 1));
        Assert.Equal("Sheet", snapshot.Title);
        Assert.Equal(ShareTheme.Dark, snapshot.Theme);
        Assert.Equal(new SourceLineMap(source).Count, snapshot.Lines.Count);
        Assert.Equal("price = 120", snapshot.Lines[0].Source);
        for (var i = 0; i < results.Count; i++)
            Assert.Equal(results[i].Display.Length == 0 ? null : results[i].Display, snapshot.Lines[i].Result);
        Assert.Equal(results[2].Display, snapshot.Lines[2].Result);
        Assert.NotNull(snapshot.Lines[2].Explanation);
        Assert.Contains("L1", snapshot.Lines[2].Explanation!);
        Assert.Null(snapshot.Lines[3].Result);
        Assert.True(snapshot.Lines[5].Error);
        Assert.Null(snapshot.Lines[5].Explanation);
        Assert.True(results[9].Error is null && results[10].Error is null, results[10].Error + " / " + results[9].Error);
        var chart = snapshot.Lines[9].Figure!;
        Assert.Equal(ShareFigureKind.Bar, chart.Kind);
        Assert.Equal(results[9].Value!.Value.Chart.Items.Select(item => item.Magnitude), chart.Items.Select(item => item.Magnitude));
        var plot = snapshot.Lines[10].Figure!;
        Assert.Equal(ShareFigureKind.Plot, plot.Kind);
        var sampled = results[10].Value!.Value.Plot;
        Assert.Equal(sampled.X.Count, plot.Points.Count);
        Assert.All(plot.Points, point => Assert.InRange(point.X, 0, ShareLink.PlotGrid));
        Assert.True(plot.Segments.Count >= 2, "1/x has a pole, so the plot keeps separate segments");
        var decoded = ShareLink.Decode(ShareLink.Create(Viewer, snapshot));
        Assert.Equal(ShareLink.Serialize(snapshot), ShareLink.Serialize(decoded));
    }

    [Fact]
    public void SnapshotIsFrozenAndHostExplanationsAreUsed()
    {
        var results = SheetEvaluator.Evaluate("a = 2\na * 3");
        var snapshot = ShareLink.Capture("S", "a = 2\na * 3", results, false, explain: answer => "host: " + answer.Display);
        var first = ShareLink.Serialize(snapshot);
        Assert.Equal("host: 6", snapshot.Lines[1].Explanation);
        Assert.Equal("a\nb\nc", ShareLink.Capture("S", "1", SheetEvaluator.Evaluate("1"), false, explain: _ => "a\r\nb\rc\r\n").Lines[0].Explanation);
        // Re-evaluating or editing the sheet later does not change an already captured snapshot.
        _ = SheetEvaluator.Evaluate("a = 5\na * 3");
        Assert.Equal(first, ShareLink.Serialize(snapshot));
        Assert.Equal(first, ShareLink.Serialize(ShareLink.Capture("S", "a = 2\na * 3", results, false, explain: answer => "host: " + answer.Display)));
    }

    [Fact]
    public void ResultsForMissingLinesAndMismatchedListsAreIgnored()
    {
        var snapshot = ShareLink.Capture("S", "1\n2", [new LineResult(5, null, "x"), new LineResult(-1, null, "y")], false);
        Assert.All(snapshot.Lines, line => Assert.Null(line.Result));
    }

    [Fact]
    public void UnpairedSurrogatesBecomeReplacementCharactersAndLongTextIsBounded()
    {
        var source = "a\uD800b 😀";
        var snapshot = ShareLink.Capture(new string('t', 200), source, SheetEvaluator.Evaluate(source), false, explain: _ => new string('e', ShareLink.MaxExplanation + 50));
        Assert.Equal("a\uFFFDb 😀", snapshot.Lines[0].Source);
        Assert.Equal(ShareLink.MaxTitle, snapshot.Title.Length);
        Assert.EndsWith("…", snapshot.Title);
        Assert.Equal("a\uFFFDb 😀", ShareLink.Decode(ShareLink.EncodeFragment(snapshot)).Lines[0].Source);
        var explained = ShareLink.Capture("S", "1+1", SheetEvaluator.Evaluate("1+1"), false, explain: _ => new string('e', ShareLink.MaxExplanation + 50));
        Assert.Equal(ShareLink.MaxExplanation, explained.Lines[0].Explanation!.Length);
        Assert.EndsWith("…", explained.Lines[0].Explanation!);
    }

    [Fact]
    public void RefusesSheetsBeyondTheLinkLimitInsteadOfTruncating()
    {
        var random = new Random(7);
        var text = string.Join('\n', Enumerable.Range(0, 2000).Select(_ => "# " + Convert.ToBase64String(Enumerable.Range(0, 48).Select(_ => (byte)random.Next(256)).ToArray())));
        var snapshot = ShareLink.Capture("S", text, [], false);
        Assert.Equal("Sheet too large to share as a link", Assert.Throws<ShareLinkException>(() => ShareLink.EncodeFragment(snapshot)).Message);
        Assert.Throws<ShareLinkException>(() => ShareLink.Capture("S", new string('1', SheetStore.MaxCharacters + 1), [], false));
    }

    [Fact]
    public void LinksCarryTheSheetOnlyInTheFragment()
    {
        var link = ShareLink.Create(new Uri("https://viewer.example.test/c/?lang=en"), Golden("starter"));
        var uri = new Uri(link);
        Assert.Equal("https://viewer.example.test/c/?lang=en", uri.GetLeftPart(UriPartial.Query));
        Assert.StartsWith("#c1.", uri.Fragment);
        Assert.DoesNotContain("price", link);
        // Raw DEFLATE: inflating the fragment bytes with a plain DeflateStream gives the canonical JSON.
        var data = uri.Fragment[4..].Replace('-', '+').Replace('_', '/');
        data += new string('=', (4 - data.Length % 4) % 4);
        using var inflated = new DeflateStream(new MemoryStream(Convert.FromBase64String(data)), CompressionMode.Decompress);
        using var reader = new StreamReader(inflated, Encoding.UTF8);
        Assert.Equal(Canonical(Golden("starter")), reader.ReadToEnd());
    }

    [Theory]
    [InlineData("https://viewer.example.test/index.html", true)]
    [InlineData("file:///C:/Program%20Files/Calc/ShareViewer/index.html", true)]
    [InlineData("http://localhost:8080/index.html", true)]
    [InlineData("http://127.0.0.1/index.html", true)]
    [InlineData("http://viewer.example.test/index.html", false)]
    [InlineData("javascript:alert(1)", false)]
    [InlineData("data:text/html,x", false)]
    [InlineData("https://user:pw@viewer.example.test/", false)]
    [InlineData("https://viewer.example.test/#old", false)]
    public void ViewerAddressesAreRestricted(string address, bool allowed)
    {
        var uri = new Uri(address);
        if (allowed) Assert.Same(uri, ShareViewerAddress.Validate(uri));
        else Assert.Throws<ShareLinkException>(() => ShareViewerAddress.Validate(uri));
    }

    [Fact]
    public void InstalledViewerIsTheDefaultAndShareJsonOverridesIt()
    {
        Directory.CreateDirectory(directory);
        var installed = ShareViewerAddress.Installed(Path.Combine(directory, "app #1"));
        Assert.True(installed.IsFile);
        Assert.Empty(installed.Fragment);
        Assert.EndsWith("/ShareViewer/index.html", installed.AbsolutePath);
        Assert.Same(installed, ShareViewerAddress.Resolve(directory, installed));
        var settings = Path.Combine(directory, ShareViewerAddress.FileName);
        File.WriteAllText(settings, "{\"viewerUrl\":\"https://viewer.example.test/calc/\"}");
        Assert.Equal("https://viewer.example.test/calc/", ShareViewerAddress.Resolve(directory, installed).AbsoluteUri);
        File.WriteAllText(settings, "{\"viewerUrl\":\"\"}");
        Assert.Same(installed, ShareViewerAddress.Resolve(directory, installed));
        File.WriteAllText(settings, "{\"viewerUrl\":\"http://viewer.example.test/\"}");
        Assert.Throws<ShareLinkException>(() => ShareViewerAddress.Resolve(directory, installed));
        File.WriteAllText(settings, "{bad");
        Assert.Throws<ShareLinkException>(() => ShareViewerAddress.Resolve(directory, installed));
        File.WriteAllText(settings, "{\"viewerUrl\":\"" + new string('a', ShareViewerAddress.MaxFileBytes) + "\"}");
        Assert.Throws<ShareLinkException>(() => ShareViewerAddress.Resolve(directory, installed));
    }

    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
}
