using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using Calc.Core;
using Calc.Documents.Export;

namespace Calc.Documents.Tests;

public sealed class ExportLayoutTests
{
    // Fixed-advance oracle: every text element is 6 units wide, so positions can be computed by hand.
    private static double Mono(string text, LayoutStyle style) => new StringInfo(text).LengthInTextElements * 6;
    private static SheetExport Export(string source) => SheetExport.Create("t", source, SheetEvaluator.Evaluate(source));

    [Fact]
    public void ResultsRightAlignToTheContentEdge()
    {
        var layout = SheetLayoutComposer.Compose(Export("# Head\n12 + 30\n1/0"), new(400, 600, 20, 16), Mono);
        var page = Assert.Single(layout.Pages);
        var result = page.Runs.Single(run => run.Text == "42");
        Assert.Equal(400 - 20 - 2 * 6, result.X);
        Assert.Equal(LayoutStyle.Result, result.Style);
        Assert.Equal(20 + 16, result.Top);
        Assert.Equal(LayoutStyle.Heading, page.Runs.Single(run => run.Text == "# Head").Style);
        var error = page.Runs.Single(run => run.Style == LayoutStyle.Error);
        Assert.Equal(400 - 20, error.X + Mono(error.Text, error.Style));
        Assert.Equal(20 + 32, error.Top);
    }

    [Fact]
    public void LongSourcesWrapInsideTheSourceColumnWithoutSplittingTextElements()
    {
        var words = string.Join(' ', Enumerable.Repeat("abcd", 30)) + " + 1";
        var layout = SheetLayoutComposer.Compose(Export(words), new(300, 2000, 10, 16), Mono);
        var sources = layout.Pages[0].Runs.Where(run => run.Style == LayoutStyle.Source).ToArray();
        var resultColumn = layout.Pages[0].Runs.Where(run => run.Style != LayoutStyle.Source).Max(run => Mono(run.Text, run.Style));
        Assert.True(sources.Length > 1);
        Assert.All(sources, run => Assert.True(Mono(run.Text, run.Style) <= 280 - Math.Min(280 * .45, resultColumn) - 24));
        Assert.Equal(words.Replace(" ", ""), string.Concat(sources.Select(run => run.Text.Replace(" ", ""))));
        var wrapped = SheetLayoutComposer.Wrap("a😀😀😀ééé", 12, LayoutStyle.Source, Mono);
        Assert.Equal(["a😀", "😀😀", "éé", "é"], wrapped);
        Assert.Equal(["  ab", "cd"], SheetLayoutComposer.Wrap("  ab cd", 24, LayoutStyle.Source, Mono));
    }

    [Fact]
    public void PaginationKeepsLinesTogetherAndBoundsPages()
    {
        var source = string.Join('\n', Enumerable.Range(1, 100).Select(i => i + " + 1"));
        var layout = SheetLayoutComposer.Compose(Export(source), new(300, 200, 20, 16), Mono);
        var perPage = (int)((200 - 40) / 16);
        Assert.Equal((int)Math.Ceiling(100d / perPage), layout.Pages.Count);
        Assert.All(layout.Pages, page => Assert.All(page.Runs, run => Assert.True(run.Top >= 20 && run.Top + 16 <= 180)));
        Assert.Equal(100, layout.Pages.Sum(page => page.Runs.Count(run => run.Style == LayoutStyle.Source)));
        Assert.Equal(Enumerable.Range(1, layout.Pages.Count), layout.Pages.Select(page => page.Number));
        Assert.Throws<ArgumentException>(() => SheetLayoutComposer.Compose(Export(source), new(300, 200, 20, 16) { MaxPages = 3 }, Mono));
    }

    [Fact]
    public void ContinuousLayoutStopsAtItsHeightAndCountsOmittedLines()
    {
        var source = string.Join('\n', Enumerable.Range(1, 50).Select(i => i.ToString(CultureInfo.InvariantCulture)));
        var layout = SheetLayoutComposer.Compose(Export(source), new(300, double.PositiveInfinity, 20, 16) { MaxHeight = 20 + 16 * 10 + 20 }, Mono);
        var page = Assert.Single(layout.Pages);
        Assert.Equal(10, page.Runs.Count(run => run.Style == LayoutStyle.Source));
        Assert.Equal(40, layout.OmittedLines);
        Assert.Equal(20 + 16 * 10 + 20, page.Height);
    }

    [Fact]
    public void FiguresSitUnderTheirLineAndWorksheetCellsShareStops()
    {
        var layout = SheetLayoutComposer.Compose(Export("plot x^2 from -2 to 2\nName\tQ1\nLonger name\t5"), new(500, 1000, 20, 16), Mono);
        var page = layout.Pages[0];
        var figure = Assert.Single(page.Figures);
        Assert.Equal((20d, 20d + 16, 460d, 120d), (figure.X, figure.Top, figure.Width, figure.Height));
        Assert.Equal(SheetValueKind.Plot, figure.Value.Kind);
        var q1 = page.Runs.Single(run => run.Text == "Q1"); var five = page.Runs.Single(run => run.Text == "5");
        Assert.Equal(20 + Mono("Longer name", LayoutStyle.Source) + 24, q1.X);
        Assert.Equal(q1.X, five.X);
        Assert.Equal(20 + 16 + 130, q1.Top);
    }

    [Fact]
    public void InvalidGeometryIsRefused()
    {
        Assert.Throws<ArgumentException>(() => SheetLayoutComposer.Compose(Export("1"), new(50, 600, 20, 16), Mono));
        Assert.Throws<ArgumentException>(() => SheetLayoutComposer.Compose(Export("1"), new(400, 40, 20, 16), Mono));
        Assert.Throws<ArgumentException>(() => SheetLayoutComposer.Compose(Export("1"), new(400, 600, 20, 0), Mono));
    }

    /// <summary>A face that maps ASCII to glyph = code point and a fixed advance; its "program" is marker bytes, so structure can be checked without a font parser.</summary>
    private sealed class FakeFace(string name, Func<int, bool> maps, double advance = 0.5) : IPdfFontFace
    {
        public string Name => name; public double Ascent => 0.8; public double Descent => 0.2; public double CapHeight => 0.7;
        public List<ushort[]> Requests { get; } = [];
        public bool TryGetGlyph(int codePoint, out ushort glyph) { glyph = maps(codePoint) ? (ushort)(codePoint & 0xFFFF) : (ushort)0; return glyph != 0; }
        public double Advance(ushort glyph) => advance;
        public (byte[] Program, bool Subset) FontProgram(IReadOnlyCollection<ushort> glyphs) { Requests.Add([.. glyphs]); return (Encoding.ASCII.GetBytes("FAKE-" + name), true); }
    }

    private static (PdfResult Result, string Text, FakeFace Latin, FakeFace Symbol) Pdf(string source)
    {
        var latin = new FakeFace("Latin Sans", c => c is >= 0x20 and < 0x7F); var symbol = new FakeFace("Symbols", c => c is 0x2248 or 0x20AC);
        var fonts = new PdfFontSet([latin, symbol], [], 10);
        var layout = SheetLayoutComposer.Compose(Export(source), new(595, 842, 50, 16), fonts.Measure);
        var result = PdfSheetWriter.Write(layout, fonts, PdfColors.Paper, "Test ✓ sheet");
        return (result, Encoding.Latin1.GetString(result.Bytes), latin, symbol);
    }

    [Fact]
    public void PdfCrossReferenceOffsetsPointAtTheirObjects()
    {
        var (result, text, _, _) = Pdf("# Budget\nrent = 1200 EUR\npi\n日本");
        Assert.StartsWith("%PDF-1.7\n", text);
        Assert.EndsWith("%%EOF\n", text);
        var startxref = int.Parse(Regex.Match(text, @"startxref\n(\d+)\n%%EOF\n$").Groups[1].Value, CultureInfo.InvariantCulture);
        Assert.StartsWith("xref\n0 ", text[startxref..]);
        var header = Regex.Match(text[startxref..], @"^xref\n0 (\d+)\n");
        var count = int.Parse(header.Groups[1].Value, CultureInfo.InvariantCulture);
        var entries = text[(startxref + header.Length)..].Split("\r\n").Take(count).ToArray();
        Assert.Equal("0000000000 65535 f", entries[0]);
        for (var id = 1; id < count; id++)
        {
            Assert.Matches(@"^\d{10} 00000 n$", entries[id]);
            var offset = int.Parse(entries[id][..10], CultureInfo.InvariantCulture);
            Assert.StartsWith(id.ToString(CultureInfo.InvariantCulture) + " 0 obj\n", text[offset..]);
        }
        Assert.Contains("/Size " + count.ToString(CultureInfo.InvariantCulture), text);
        Assert.Equal(1, result.Pages);
        // 日本 is in neither face: two visible characters are counted, drawn as glyph 0.
        Assert.Equal(2, result.MissingCharacters);
        // Title survives as UTF-16BE with a BOM.
        Assert.Contains(PdfWriter.TextString("Test ✓ sheet"), text);
        Assert.Contains("<FEFF0054006500730074002027130020", text);
    }

    [Fact]
    public void PdfDrawsGlyphCodesWithFallbackFacesAndMapsThemBackToUnicode()
    {
        var (_, text, latin, symbol) = Pdf("€ 5 ≈ 5");
        var streams = Streams(text);
        var content = streams.Single(s => s.Contains("BT\n", StringComparison.Ordinal));
        // ASCII from the primary face, € and ≈ from the fallback face, each segment positioned with its own Tm.
        Assert.Contains("/F1 10 Tf", content); Assert.Contains("/F2 10 Tf", content);
        Assert.Contains("<20AC> Tj", content);
        Assert.Contains("<002000350020> Tj", content);
        // The fallback segment starts where the primary face's advances end: x = margin + 1 glyph * 0.5 em * 10.
        Assert.Contains("1 0 0 1 55 ", content);
        Assert.Contains("<2248> Tj", content);
        var maps = streams.Where(s => s.Contains("beginbfchar", StringComparison.Ordinal)).ToArray();
        Assert.Equal(2, maps.Length);
        Assert.Contains(maps, map => map.Contains("<20AC> <20AC>", StringComparison.Ordinal) && map.Contains("<2248> <2248>", StringComparison.Ordinal));
        Assert.Contains(maps, map => map.Contains("<0035> <0035>", StringComparison.Ordinal));
        // Each embedded program was requested once with exactly the glyphs drawn, plus the missing glyph.
        Assert.Equal(new ushort[] { 0, 0x20AC, 0x2248 }, Assert.Single(symbol.Requests).Order());
        Assert.Contains((ushort)0, Assert.Single(latin.Requests));
        Assert.Contains("FAKE-Latin Sans", string.Join("", streams));
        Assert.Matches(@"/BaseFont /[A-Z]{6}\+LatinSans ", text);
        Assert.Contains("/Encoding /Identity-H", text);
        Assert.Contains("/CIDToGIDMap /Identity", text);
    }

    [Fact]
    public void PdfOutputIsDeterministic()
    {
        Assert.Equal(Pdf("a = 1\nb = a * 2").Result.Bytes, Pdf("a = 1\nb = a * 2").Result.Bytes);
    }

    [Fact]
    public void PdfEmbedsFigureImagesAndRefusesMalformedOnes()
    {
        var face = new FakeFace("Latin", c => c is >= 0x20 and < 0x7F);
        var fonts = new PdfFontSet([face], [], 10);
        var layout = SheetLayoutComposer.Compose(Export("plot x from 0 to 1"), new(595, 842, 50, 16), fonts.Measure);
        var pdf = Encoding.Latin1.GetString(PdfSheetWriter.Write(layout, fonts, PdfColors.Paper, "t", _ => new PdfImage(2, 1, [255, 0, 0, 0, 0, 255])).Bytes);
        Assert.Contains("/Subtype /Image /Width 2 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8", pdf);
        Assert.Contains("/XObject << /Im1 ", pdf);
        Assert.Contains(Streams(pdf), s => s.Contains("cm /Im1 Do Q", StringComparison.Ordinal));
        Assert.Throws<ArgumentException>(() => PdfSheetWriter.Write(layout, fonts, PdfColors.Paper, "t", _ => new PdfImage(2, 2, [1, 2, 3])));
        Assert.Throws<ArgumentException>(() => PdfSheetWriter.Write(SheetLayoutComposer.Compose(Export("1"), new(595, double.PositiveInfinity, 50, 16), fonts.Measure), fonts, PdfColors.Paper, "t"));
    }

    // Decompresses every Flate stream using each dictionary's declared /Length.
    private static List<string> Streams(string pdf)
    {
        var streams = new List<string>();
        foreach (Match match in Regex.Matches(pdf, @"/Filter /FlateDecode /Length (\d+) >>\nstream\n"))
        {
            var length = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
            var start = match.Index + match.Length;
            Assert.Equal("\nendstream", pdf.Substring(start + length, 10));
            using var input = new ZLibStream(new MemoryStream(Encoding.Latin1.GetBytes(pdf.Substring(start, length))), CompressionMode.Decompress);
            using var output = new MemoryStream(); input.CopyTo(output);
            streams.Add(Encoding.Latin1.GetString(output.ToArray()));
        }
        return streams;
    }
}
