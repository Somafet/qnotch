using System.Text;
using Calc.Core;
using Calc.Documents.Export;
using Microsoft.VisualBasic.FileIO;

namespace Calc.Documents.Tests;

public sealed class ExportTests
{
    private const string Groceries = "# Groceries\nmilk = 3.50\nbread = 2.25\nsum\n\nnote: buy later\n2/3\n1/0";
    private static SheetExport Export(string source, string title = "Groceries") => SheetExport.Create(title, source, SheetEvaluator.Evaluate(source));

    [Fact]
    public void SnapshotClassifiesLinesAndFindsTheSheetTotal()
    {
        var export = Export(Groceries);
        Assert.Equal([ExportLineKind.Heading, ExportLineKind.Result, ExportLineKind.Result, ExportLineKind.Result, ExportLineKind.Blank, ExportLineKind.Error, ExportLineKind.Result, ExportLineKind.Error],
            export.Lines.Select(line => line.Kind));
        Assert.Equal([false, false, false, true, false, false, false, false], export.Lines.Select(line => line.IsTotal));
        Assert.Equal("5.75", export.TotalText); // 3.50 + 2.25
        Assert.Equal(Enumerable.Range(1, 8), export.Lines.Select(line => line.Number));
    }

    [Fact]
    public void ResultsReadAsTheSheetShowsThemWithNumberStyleAndDefaultCurrency()
    {
        var latest = new CurrencyRateSnapshot("Test daily rates", "EUR", new(2026, 10, 30), new(2026, 10, 30, 17, 0, 0, TimeSpan.Zero),
            new Dictionary<string, Rational> { ["EUR"] = new(1, 1), ["USD"] = new(2, 1), ["HUF"] = new(400, 1) });
        var context = new EvaluationContext(new(2026, 10, 31), CurrencyRates: new(latest, new Dictionary<DateOnly, CurrencyRateSnapshot>())) { DisplayCurrency = "HUF" };
        const string source = "6400 usd\n1234567\n6400 usd in usd";
        var format = new ResultFormat(null, NumberStyle.FromId("comma", System.Globalization.CultureInfo.InvariantCulture));
        var export = SheetExport.Create("t", source, SheetEvaluator.Evaluate(source, context: context), format);
        Assert.Equal(["1,280,000 HUF", "1,234,567", "6,400 USD"], export.Lines.Select(line => line.Result));
        Assert.Equal("1280000 HUF", export.Lines[0].Value); // click-copy text of the shown amount
        // Without a format the canonical display remains, as before.
        Assert.Equal("1234567", SheetExport.Create("t", source, SheetEvaluator.Evaluate(source, context: context)).Lines[1].Result);
    }

    [Fact]
    public void AggregateFlagMarksOnlySumAndAverageLines()
    {
        var results = SheetEvaluator.Evaluate("1\n2\nsum\naverage\nsum([1,2])\nx = 4");
        Assert.Equal([false, false, true, true, false, false], results.Select(result => result.IsAggregate));
        Assert.Null(SheetExport.Create("", "1\n2", SheetEvaluator.Evaluate("1\n2")).TotalText);
        // The last declared total wins when a sheet has several blocks.
        Assert.Equal("10", Export("1\n2\nsum\n\n4\n6\nsum").TotalText);
    }

    [Fact]
    public void ResultsTextKeepsLineCorrespondenceAndCompleteValues()
    {
        Assert.Equal("\r\n3.5\r\n2.25\r\n5.75\r\n\r\n\r\n2/3", Export(Groceries).ResultsText());
        // A named constant shows compact notation; copy keeps every digit.
        var constant = Export("c");
        Assert.Equal(constant.Lines[0].Value, constant.ResultsText());
        Assert.NotEqual(constant.Lines[0].Result, constant.Lines[0].Value);
    }

    [Fact]
    public void PlainTextRightAlignsResultsInOneColumn()
    {
        // Source column is the widest calculated source (12) plus a two-space gap; results right-align to the widest result (16).
        static string Row(string source, string result) => source + new string(' ', 14 + 16 - source.Length - result.Length) + result;
        var expected = string.Join("\r\n", "# Groceries", Row("milk = 3.50", "3.5"), Row("bread = 2.25", "2.25"), Row("sum", "5.75"), "",
            Row("2/3", "2/3"), Row("1/0", "Division by zero"), "");
        Assert.Equal(expected, Export("# Groceries\nmilk = 3.50\nbread = 2.25\nsum\n\n2/3\n1/0").PlainText());
        // A source longer than the column cap pushes only its own result, by the minimum gap.
        var longSource = new string('1', 60) + " + 1";
        Assert.EndsWith(longSource + "  " + Export(longSource).Lines[0].Result + "\r\n", Export(longSource).PlainText());
    }

    [Fact]
    public void DisplayWidthCountsWideAndCombiningCharacters()
    {
        Assert.Equal(4, SheetExport.DisplayWidth("日本"));
        Assert.Equal(1, SheetExport.DisplayWidth("é"));
        Assert.Equal(2, SheetExport.DisplayWidth("😀"));
        Assert.Equal(3, SheetExport.DisplayWidth("abc"));
    }

    [Fact]
    public void MarkdownKeepsHeadingsTablesAndEscapesMarkup()
    {
        var source = "# Costs | 2026\nrent = 1200\nfee_total = 3*4\nsum\n\n// reminder *later*\n\nName\tQ1\nA|B\t5";
        var markdown = Export(source).Markdown();
        Assert.Equal(string.Join("\r\n",
            "# Costs \\| 2026", "",
            "| | |", "| --- | ---: |", "| rent = 1200 | 1200 |", "| fee\\_total = 3\\*4 | 12 |", "| sum | **1212** |", "",
            "// reminder \\*later\\*", "",
            "| Name | Q1 |", "| --- | --- |", "| A\\|B | 5 |", ""), markdown);
    }

    [Fact]
    public void CsvRoundTripsThroughAnIndependentParserAndGuardsFormulas()
    {
        var source = "label = \"a, \"\"quoted\"\" b\"\n=1+1\n-5 + 2\n-3\n@x\n2/3\n\nplain words";
        var export = Export(source);
        var csv = export.Csv();
        using var parser = new TextFieldParser(new StringReader(csv)) { TextFieldType = FieldType.Delimited, HasFieldsEnclosedInQuotes = true };
        parser.SetDelimiters(",");
        var rows = new List<string[]>();
        while (!parser.EndOfData) rows.Add(parser.ReadFields()!);
        Assert.Equal(["Line", "Source", "Result", "Value", "Error"], rows[0]);
        Assert.Equal(export.Lines.Count(line => line.Kind != ExportLineKind.Blank) + 1, rows.Count);
        Assert.Equal(source.Split('\n')[0], rows[1][1]);
        Assert.Equal("'=1+1", rows[2][1]);
        Assert.Equal("'-5 + 2", rows[3][1]);
        Assert.Equal("-3", rows[4][1]); // a plain signed number stays numeric
        Assert.Equal("-3", rows[4][2]);
        Assert.Equal("'@x", rows[5][1]);
        Assert.Equal(["6", "2/3", "2/3", "2/3", ""], rows[6]);
        Assert.Equal("8", rows[7][0]);
        Assert.All(rows, row => Assert.Equal(5, row.Length));
        Assert.EndsWith("\r\n", csv);
    }

    [Fact]
    public void TableRowsKeepWorksheetCellsAndResults()
    {
        var export = Export("Name\tQ1\tQ2\nA\t1\t2\n\nx = 2 + 3");
        Assert.Equal([["Name", "Q1", "Q2", export.Lines[0].Result], ["A", "1", "2"], ["x = 2 + 3", "5"]], export.TableRows().Select(row => row.ToArray()).ToArray());
        Assert.Equal("Name\tQ1\tQ2\t" + export.Lines[0].Result + "\r\nA\t1\t2\r\nx = 2 + 3\t5", export.TableTsv());
        Assert.Equal("<table><tr><td>a &lt;b&gt; &amp; c</td><td>1</td></tr></table>", Export("a <b> & c\t1").TableHtml());
    }

    [Fact]
    public void ClipboardHtmlOffsetsAreUtf8BytePositions()
    {
        var fragment = "<table><tr><td>€ 5 · 日本 😀</td></tr></table>";
        var payload = ClipboardHtml.Wrap(fragment);
        var bytes = Encoding.UTF8.GetBytes(payload);
        int Offset(string key) { var at = payload.IndexOf(key + ":", StringComparison.Ordinal) + key.Length + 1; return int.Parse(payload.Substring(at, 10)); }
        Assert.Equal(fragment, Encoding.UTF8.GetString(bytes, Offset("StartFragment"), Offset("EndFragment") - Offset("StartFragment")));
        Assert.StartsWith("<html>", Encoding.UTF8.GetString(bytes, Offset("StartHTML"), 6));
        Assert.Equal(bytes.Length, Offset("EndHTML"));
    }

    [Fact]
    public void ExportsAreBounded()
    {
        Assert.Throws<ArgumentException>(() => SheetExport.Create("x", new string('1', SheetStore.MaxCharacters + 1), []));
        Assert.Throws<ArgumentException>(() => SheetExport.Create("x", string.Concat(Enumerable.Repeat("1\n", SheetEvaluator.MaxLines)), []));
        // A full-size sheet still exports within the output limit.
        var full = string.Concat(Enumerable.Repeat("123456789 + 1\n", 9_999));
        var export = Export(full);
        Assert.True(export.PlainText().Length < SheetExport.MaxOutputCharacters);
        Assert.Equal(9_999 + 1, export.Csv().Split("\r\n").Length - 1);
    }

    [Fact]
    public void MismatchedOrMissingResultsExportSourceOnly()
    {
        var export = SheetExport.Create("t", "1+1\n2+2", [new LineResult(5, null, "stale")]);
        Assert.All(export.Lines, line => Assert.Equal(ExportLineKind.Text, line.Kind));
        Assert.Equal("1+1\r\n2+2\r\n", export.PlainText());
    }

    [Fact]
    public void ExportFileReplacesAtomicallyAndSuggestsSafeNames()
    {
        var directory = Directory.CreateTempSubdirectory("calc-export-");
        try
        {
            var path = Path.Combine(directory.FullName, "out.csv");
            File.WriteAllText(path, "old");
            ExportFile.Write(path, ExportFile.Encode(ExportFormat.Csv, "a,b\r\n"));
            Assert.Equal([0xEF, 0xBB, 0xBF, (byte)'a'], File.ReadAllBytes(path).Take(4));
            Assert.Single(directory.GetFiles());
            Assert.Equal("Plan 2026 Q1.md", ExportFile.SuggestedName("Plan: 2026/Q1", ExportFormat.Markdown));
            Assert.Equal("con sheet.pdf", ExportFile.SuggestedName("con", ExportFormat.Pdf));
            Assert.Equal("Sheet.txt", ExportFile.SuggestedName("  ?? ", ExportFormat.PlainText));
            Assert.Equal("a.png", ExportFile.SuggestedName("a", ExportFormat.TransparentPng));
        }
        finally { directory.Delete(true); }
    }
}
