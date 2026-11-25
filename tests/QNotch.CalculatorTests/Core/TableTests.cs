using Calc.Core;

namespace Calc.Core.Tests;

public class TableTests
{
    private const string Sales = "Region\tQ1\tQ2\tNotes\nNorth\t10\t40\tgood\nSouth\t20\t\tlate\nEast\t60\t90\t-\nWest\tn/a\t20\t";
    private static LineResult Last(string source) => SheetEvaluator.Evaluate(source)[^1];
    private static TableValue Table(string source) { var result = SheetEvaluator.Evaluate(source).First(line => line.Value?.Kind == SheetValueKind.Table); return result.Value!.Value.Table; }

    [Fact]
    public void FirstLineShowsTheShapeAndOtherLinesStayQuiet()
    {
        var results = SheetEvaluator.Evaluate("a\tb\n1\t2\n3\t4");
        Assert.Equal("2×2 table", results[0].Display);
        Assert.All(results.Skip(1), line => { Assert.Equal("", line.Display); Assert.Null(line.Error); });
    }

    [Fact]
    public void OneDataRowUnderAHeaderIsATable() => Assert.Equal("1×2 table", SheetEvaluator.Evaluate("a\tb\n1\t2")[0].Display);

    [Theory]
    [InlineData("a\tb\n1\t2\n3\t4", true, 2)]
    [InlineData("1\tb\n1\t2", true, 1)]
    [InlineData("1\t2\n3\t4", false, 2)]
    [InlineData("10%\t$5\n3\t4", false, 2)]
    [InlineData("1\t\t3\n4\t5\t6", false, 2)]
    public void HeaderIsDetectedFromNonNumericFirstRowCells(string source, bool header, int rows)
    {
        var table = Table(source);
        Assert.Equal(header, table.Header is not null); Assert.Equal(rows, table.RowCount);
    }

    [Theory]
    [InlineData("sum", "90")]
    [InlineData("avg", "30")]
    [InlineData("average", "30")]
    [InlineData("mean", "30")]
    [InlineData("min", "10")]
    [InlineData("max", "60")]
    [InlineData("count", "3")]
    [InlineData("median", "20")]
    public void ColumnStatisticsSkipTextCells(string function, string display) => Assert.Equal(display, Last(Sales + "\n\n" + function + "(column(table1, \"Q1\"))").Display);

    [Theory]
    [InlineData("sum", "150")]
    [InlineData("avg", "50")]
    [InlineData("min", "20")]
    [InlineData("max", "90")]
    [InlineData("count", "3")]
    [InlineData("median", "40")]
    public void BlankCellsAreSkippedByPosition(string function, string display) => Assert.Equal(display, Last(Sales + "\n\n" + function + "(column(table1, 3))").Display);

    [Theory]
    [InlineData("sum", "150")]
    [InlineData("avg", "75")]
    [InlineData("min", "60")]
    [InlineData("max", "90")]
    [InlineData("count", "2")]
    [InlineData("median", "75")]
    public void RowStatisticsSkipLabels(string function, string display) => Assert.Equal(display, Last(Sales + "\n\n" + function + "(row(table1, 3))").Display);

    [Theory]
    [InlineData("column(table1, \"q1\")", "[10, 20, 60]")]
    [InlineData("row(table1, 1)", "[10, 40]")]
    public void SelectionsAreOrdinaryLists(string call, string display)
    {
        var result = Last(Sales + "\n\n" + call);
        Assert.Equal(SheetValueKind.List, result.Value!.Value.Kind); Assert.Equal(display, result.Display);
    }

    [Fact]
    public void ListFormOfCountAndMedianStillWork()
    {
        Assert.Equal("3", Last("count([1, 2, 3])").Display);
        Assert.Equal("2", Last("median([1, 2, 3])").Display);
        Assert.Equal("6", Last("sum([1, 2, 3])").Display);
    }

    [Fact]
    public void ExplanationCountsSkippedCells() => Assert.Contains("1 text or blank cells skipped", Last(Sales + "\n\ncolumn(table1, \"Q1\")").Explanation[^1].Assumption);

    [Fact]
    public void CellsCoverPercentagesMoneyAndUnits()
    {
        var table = Table("rate\tcost\tweight\n10%\t$5\t2 kg\n25%\t$7.50\t500 g");
        Assert.Equal("35%", Last("t:\nrate\tcost\tweight\n10%\t$5\t2 kg\n25%\t$7.50\t500 g\n\nsum(column(t, 1))").Display);
        Assert.Equal(SheetValueKind.Money, table[0, 1].Value!.Value.Kind);
        Assert.Equal("2.5 kg", Last("t:\nrate\tcost\tweight\n10%\t$5\t2 kg\n25%\t$7.50\t500 g\n\nsum(column(t, 3))").Display);
    }

    [Theory]
    [InlineData("1,234.50", "1234.5")]
    [InlineData("$1,200", "$1200")]
    [InlineData("-5", "-5")]
    [InlineData("1k", "1000")]
    public void CommonSpreadsheetFormatsAreNumbers(string cell, string value) => Assert.Contains(value.TrimStart('$'), Table("a\tb\n" + cell + "\t1")[0, 0].Value!.Value.Display.Replace(",", ""));

    [Theory]
    [InlineData("Q1")]
    [InlineData("1,5")]
    [InlineData("1.234,56")]
    [InlineData("(5)")]
    [InlineData("2 + 3")]
    [InlineData("2026-01-15")]
    [InlineData("10:30")]
    [InlineData("1.2.3.4")]
    [InlineData("x = 5")]
    [InlineData("sum(1, 2)")]
    public void OtherCellsAreText(string cell) => Assert.Null(Table("a\tb\n" + cell + "\t1")[0, 0].Value);

    [Fact]
    public void TableLinesNeverProduceCellErrors()
    {
        var results = SheetEvaluator.Evaluate("a\tb\n)(\t1/0\n1 +\t[\n\"open\t5");
        Assert.All(results, line => Assert.Null(line.Error));
    }

    [Fact]
    public void TableLinesStayOutOfBlockAggregates()
    {
        Assert.Equal("3", Last("1\na\tb\n5\t6\n2\nsum").Display);
        Assert.Equal("1.5", Last("1\na\tb\n5\t6\n2\naverage").Display);
        Assert.Equal([1d, 2], Last("1\na\tb\n5\t6\n2\nbar chart").Value!.Value.Chart.Items.Select(item => item.Magnitude));
    }

    [Fact]
    public void NameLineNamesTheTableAndShowsNothing()
    {
        var results = SheetEvaluator.Evaluate("sales:\na\tb\n1\t2\n\nsum(column(sales, \"b\"))");
        Assert.Equal("", results[0].Display); Assert.Null(results[0].Error);
        Assert.Equal("1×2 table", results[1].Display);
        Assert.Equal("2", results[^1].Display);
    }

    [Fact]
    public void UnnamedTablesNumberInSourceOrder()
    {
        var source = "a\tb\n1\t2\n\nnamed:\na\tb\n3\t4\n\na\tb\n5\t6\n\nsum(column(table1, 2))\nsum(column(table2, 2))";
        var results = SheetEvaluator.Evaluate(source);
        Assert.Equal("2", results[^2].Display); Assert.Equal("6", results[^1].Display);
    }

    [Fact]
    public void UserVariableKeepsItsName()
    {
        var results = SheetEvaluator.Evaluate("a\tb\n1\t2\n\ntable1 = 7\ntable1 + 1");
        Assert.Equal("8", results[^1].Display);
    }

    [Fact]
    public void InvalidNameLineIsLeftAloneAndTheTableIsAutoNamed() => Assert.Equal("2", Last("Totals (EUR):\na\tb\n1\t2\n\nsum(column(table1, 2))").Display);

    [Theory]
    [InlineData("a\tb\n1\t2\t3")]
    [InlineData("a\tb\nplain\nc\td")]
    [InlineData("a\tb")]
    [InlineData("\tx = 1\n\ty = 2")]
    [InlineData("x = 1\t\ny = 2\t")]
    [InlineData("# heading\tone\n# heading\ttwo")]
    public void OtherTabbedTextIsNotATable(string source) => Assert.DoesNotContain(SheetEvaluator.Evaluate(source), line => line.Value?.Kind == SheetValueKind.Table);

    [Fact]
    public void IndentedLinesKeepEvaluating() => Assert.Equal("3", Last("\tx = 1\n\ty = 2\n\tx + y").Display);

    [Theory]
    [InlineData("column(table1, \"Q9\")", "Unknown column")]
    [InlineData("column(table1, 0)", "from 1 to 4")]
    [InlineData("column(table1, 5)", "from 1 to 4")]
    [InlineData("column(table1, 1.5)", "whole number")]
    [InlineData("row(table1, 5)", "from 1 to 4")]
    [InlineData("column(table1, \"Region\")", "no numeric cells")]
    [InlineData("column(5, 1)", "expects a table")]
    public void BadSelectionsAreExplicitErrors(string call, string message) => Assert.Contains(message, Last(Sales + "\n\n" + call).Error);

    [Theory]
    [InlineData("a\ta\n1\t2\n\ncolumn(table1, \"A\")", "More than one column")]
    [InlineData("1\t2\n3\t4\n\ncolumn(table1, \"A\")", "no header")]
    public void HeaderAmbiguityIsExplicit(string source, string message) => Assert.Contains(message, Last(source).Error);

    [Theory]
    [InlineData("table1 + 1")]
    [InlineData("sum(table1)")]
    [InlineData("-table1")]
    public void WholeTableArithmeticIsAnError(string line) => Assert.NotNull(Last("a\tb\n1\t2\n\n" + line).Error);

    [Fact]
    public void LimitsReportOnceOnTheFirstLine()
    {
        var wide = string.Join('\t', Enumerable.Range(1, 65));
        var results = SheetEvaluator.Evaluate(wide + "\n" + wide);
        Assert.Contains("64 columns", results[0].Error); Assert.Null(results[1].Error);
        var tall = "a\tb\n" + string.Join('\n', Enumerable.Repeat("1\t2", 1025));
        Assert.Contains("1024 rows", SheetEvaluator.Evaluate(tall)[0].Error);
        Assert.Equal("1024×2 table", SheetEvaluator.Evaluate("a\tb\n" + string.Join('\n', Enumerable.Repeat("1\t2", 1024)))[0].Display);
    }

    [Fact]
    public void CellEditUpdatesDependentsAndOnlyThose()
    {
        var session = new SheetEvaluationSession();
        var before = "t:\na\tb\n1\t2\n3\t4\n\nx = sum(column(t, 2))\ny = 5\nz = y + 1";
        Assert.Equal("6", session.Evaluate(before)[5].Display);
        var results = session.Evaluate(before.Replace("3\t4", "3\t40"));
        Assert.Equal("42", results[5].Display); Assert.Equal("6", results[7].Display);
        // The table and x evaluate; y, z, and the quiet lines are reused.
        Assert.Equal(2, session.LastStatistics.EvaluatedLines);
        Assert.Equal(2, session.LastStatistics.ReusedResults);
        Assert.Equal(1, session.LastStatistics.ParsedLines);
    }

    [Fact]
    public void ReformattingACellLeavesDependentsReusable()
    {
        var session = new SheetEvaluationSession();
        var first = session.Evaluate("a\tb\n1\t2\n\nx = sum(column(table1, 2))");
        var second = session.Evaluate("a\tb\n1\t2.0\n\nx = sum(column(table1, 2))");
        Assert.Same(first[3], second[3]);
        Assert.Equal(first[0].Value, second[0].Value);
    }

    [Fact]
    public void DroppingATableRowRebindsTheName()
    {
        var session = new SheetEvaluationSession();
        var line = "x = sum(column(table1, 2))";
        Assert.Equal("6", session.Evaluate("a\tb\n1\t2\n3\t4\n\n" + line)[^1].Display);
        Assert.Equal("2", session.Evaluate("a\tb\n1\t2\nplain\n\n" + line)[^1].Display);
    }

    [Fact]
    public void ChartsReadTableColumnsWithLabels()
    {
        var chart = Last(Sales + "\n\nbar chart of column(table1, \"Q1\")").Value!.Value.Chart;
        Assert.Equal(["North", "South", "East"], chart.Items.Select(item => item.Label));
        var row = Last(Sales + "\n\npie chart of row(table1, 3)").Value!.Value.Chart;
        Assert.Equal(["Q1", "Q2"], row.Items.Select(item => item.Label));
    }

    [Fact]
    public void TablesPassThroughSavedFunctions()
    {
        var library = new FunctionLibrary([new("firstTotal", ["t"], "sum(column(t, 2))")]);
        Assert.Equal(FunctionLibrary.LatestCatalogVersion, library.MinimumCatalogVersion);
        Assert.Equal("6", new SheetEvaluationSession().EvaluateWithFunctions("a\tb\n1\t2\n3\t4\n\nfirstTotal(table1)", library, []).Results[^1].Display);
    }

    [Fact]
    public void TableCellsAreNotFunctionDefinitions()
    {
        var update = FunctionUpdate.Prepare("f(x) = 1\t2\nf(y) = 3\t4", FunctionLibrary.Empty, []);
        Assert.Empty(update.Library.Definitions);
    }

    [Fact]
    public void CopyTextIsCompact() => Assert.Equal("4×4 table: Region, Q1, Q2, Notes", Last(Sales).Value is null ? SheetEvaluator.Evaluate(Sales)[0].Value!.Value.CopyText : "");

    [Theory]
    [InlineData("a,b\n1,2\n", "a\tb\n1\t2\n")]
    [InlineData("a,b\r\n1,2\r\n3,4", "a\tb\n1\t2\n3\t4")]
    [InlineData("a;b;c\n1;2;3", "a\tb\tc\n1\t2\t3")]
    [InlineData("name,note\n\"Smith, J\",1", "name\tnote\nSmith, J\t1")]
    [InlineData("name,note\n\"said \"\"hi\"\"\",1", "name\tnote\nsaid \"hi\"\t1")]
    [InlineData("name,note\n\"two\nlines\",1", "name\tnote\ntwo lines\t1")]
    [InlineData("a, b\n1, 2", "a\tb\n1\t2")]
    [InlineData("a;b\n1,5;2,5", "a\tb\n1,5\t2,5")]
    [InlineData("a,b,\n1,2,", "a\tb\t\n1\t2\t")]
    public void Rfc4180AndSemicolonTextBecomesTsv(string paste, string expected) => Assert.Equal(expected, TableSyntax.TryNormalizePaste(paste));

    [Theory]
    [InlineData("")]
    [InlineData("a,b,c")]
    [InlineData("a,b,c\n")]
    [InlineData("a,b\n1,2,3")]
    [InlineData("a,b\n\n1,2")]
    [InlineData("a\tb\n1\t2")]
    [InlineData("a,\"b\n1,2")]
    [InlineData("a,b\"c\n1,2")]
    [InlineData("\"a\"b,c\n1,2")]
    [InlineData("sum(1, 2)\nmax(3, 4)")]
    [InlineData("[1, 2]\n[3, 4]")]
    [InlineData("a = 1, 2\nb = 3, 4")]
    [InlineData("Hello, world\nGoodbye, moon")]
    [InlineData("one\ntwo")]
    [InlineData(",a\n1,2")]
    public void EverythingElseIsLeftUntouched(string paste) => Assert.Same(paste, TableSyntax.TryNormalizePaste(paste));

    [Fact]
    public void WideOrTallPastesStayText()
    {
        var wide = string.Join(',', Enumerable.Range(1, 65)); var text = wide + "\n" + wide;
        Assert.Same(text, TableSyntax.TryNormalizePaste(text));
        var tall = "a,b\n" + string.Join('\n', Enumerable.Repeat("1,2", 1025));
        Assert.Same(tall, TableSyntax.TryNormalizePaste(tall));
    }

    [Fact]
    public void NormalizedPasteEvaluatesAsATable()
    {
        var source = TableSyntax.TryNormalizePaste("item,cost\n\"Rent, flat\",\"$1,200.50\"\nFood,$300\n");
        var results = SheetEvaluator.Evaluate(source + "\nsum(column(table1, \"cost\"))");
        Assert.Equal("2×2 table", results[0].Display);
        Assert.Contains("1500.5", results[^1].Display.Replace(",", ""));
    }

    [Fact]
    public void TabAlignedLabelAmountLinesStayOrdinaryLines()
    {
        var results = SheetEvaluator.Evaluate("rent\t1200\nfood\t400\nsum");
        Assert.DoesNotContain(results, line => line.Value?.Kind == SheetValueKind.Table);
        Assert.Equal("1600", results[^1].Display);
        // A name line still makes the same lines a table; its first row is then the header, as for any table.
        Assert.Equal("1×2 table", SheetEvaluator.Evaluate("budget:\nrent\t1200\nfood\t400")[1].Display);
        Assert.Equal("1600", Last("budget:\nitem\tcost\nrent\t1200\nfood\t400\n\nsum(column(budget, 2))").Display);
        Assert.Equal("1×2 table", SheetEvaluator.Evaluate("item\tcost\nrent\t1200")[0].Display);
    }

    [Theory]
    [InlineData("1,200\r\n3,400\r\n")]
    [InlineData("$1,200\n$3,400\n")]
    [InlineData("3,5\n4,25")]
    [InlineData("Milk, 2 l\nEggs, 12")]
    public void FormattedNumberColumnsAreNotCsv(string paste) => Assert.Same(paste, TableSyntax.TryNormalizePaste(paste));
}
