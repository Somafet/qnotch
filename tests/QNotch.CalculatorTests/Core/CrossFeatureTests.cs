using Calc.Core;

namespace Calc.Core.Tests;

/// <summary>Interactions between the merged formula, complex/constant/prime, practical helper and worksheet features. Each expectation is derived by hand.</summary>
public class CrossFeatureTests
{
    private static LineResult Last(string source) => SheetEvaluator.Evaluate(source)[^1];
    private static string Display(string source) { var result = Last(source); Assert.Null(result.Error); return result.Display; }
    private static int Schema(params string[] bodies) => FunctionUpdate.Prepare(string.Join("\n", bodies), FunctionLibrary.Empty, []).Library.MinimumCatalogVersion;

    [Theory]
    [InlineData("i = 2\ni * 3", "6")]                          // the variable wins over the imaginary unit
    [InlineData("c = 3\nc + 1", "4")]                          // the variable wins over the speed of light
    [InlineData("i = 2\nsolve x * i = 6", "x = 3")]             // 2x = 6
    [InlineData("c = 3\nintegral(c * x, 0, 2)", "6")]          // c * 2^2 / 2
    [InlineData("pace = 3\npace * 2", "6")]                    // a user variable beats the helper sentence word
    [InlineData("plot = 4\nplot + 1", "5")]                    // and the worksheet word
    public void UserVariablesShadowConstantsUnitsAndSentenceWords(string source, string display) => Assert.Equal(display, Display(source));

    [Theory]
    [InlineData("k = 9\nsolve x^2 = k", "x = -3 or x = 3")]
    [InlineData("k = 5\nsolve 2x + k = 11", "x = 3")]
    public void SolveReadsSheetVariables(string source, string display) => Assert.Equal(display, Display(source));

    [Theory]
    [InlineData("2 * integral(x^2, 0, 3) + 1", "19")]          // 2 * 9 + 1
    [InlineData("integral(x, 0, 2) * (1 + i)", "2 + 2i")]       // 2 * (1 + i)
    [InlineData("derivative(x^2, 3) - 6", "0")]                 // d/dx x^2 = 2x at 3
    public void CalculusResultsComposeWithArithmetic(string source, string display) => Assert.Equal(display, Display(source));

    [Fact]
    public void FigureTableAndNonScalarLinesNeverReachBlockTotals()
    {
        // Only 10 and 20 are scalar members; every other line is a figure, a table, a complex, prime or zones result.
        var source = "10\n20\nplot x^2\nbar chart of [1, 2]\n3 + 4i\nisprime(7)\nfactor(12)\nhr zones age 30\nsolve x = 1\nsum";
        var results = SheetEvaluator.Evaluate(source);
        Assert.All(results, result => Assert.Null(result.Error));
        Assert.Equal("30", results[^1].Display);
        Assert.Equal("15", Last(source.Replace("\nsum", "\naverage")).Display);
        Assert.Equal("3", Last("1\n2\npie chart\nsum").Display); // the chart reads the block, the sum skips the chart
    }

    [Fact]
    public void ChartsReadTableColumnsAndRows()
    {
        const string table = "item\tcost\nrent\t1200\nfood\t300\nfun\t100";
        var column = Last(table + "\n\nbar chart of column(table1, \"cost\")");
        Assert.Null(column.Error); Assert.Equal(SheetValueKind.Chart, column.Value!.Value.Kind);
        Assert.Equal("1600", column.Display); // 1200 + 300 + 100
        Assert.Equal("1600", Display(table + "\n\nsum(column(table1, 2))"));
    }

    [Fact]
    public void SavedFunctionsCarryComplexHelperAndWorksheetSyntax()
    {
        var update = FunctionUpdate.Prepare("sq(z) = z^2\nrest(w) = bmr w 180 cm 30 years male\nwave(a) = plot a * sin(x) from 0 to 6", FunctionLibrary.Empty, []);
        var reloaded = new FunctionLibrary(update.Library.Definitions);
        Assert.Equal(update.Library.Fingerprint, reloaded.Fingerprint);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("sq(1 + i)\nrest(80 kg)\nwave(2)", reloaded, []).Results;
        Assert.All(results, result => Assert.Null(result.Error));
        Assert.Equal("2i", results[0].Display);                   // (1 + i)^2 = 1 + 2i - 1
        Assert.Equal("1780 kcal", results[1].Display);            // 10*80 + 6.25*180 - 5*30 + 5
        Assert.Equal(SheetValueKind.Plot, results[2].Value!.Value.Kind);
    }

    [Fact]
    public void CatalogSchemaFourStaysForFormulaOnlyBodiesAndFiveCoversEveryNewSyntax()
    {
        Assert.Equal(4, FunctionLibrary.FormulaCatalogVersion); Assert.Equal(5, FunctionLibrary.LatestCatalogVersion);
        Assert.Equal(1, Schema("plain(v) = v + 1"));
        Assert.Equal(4, Schema("area(b) = integral(x^2, 0, b)"));
        Assert.Equal(4, Schema("roots(c) = solve x^2 = c"));
        Assert.Equal(4, Schema("circle(r) = pi * r^2"));
        Assert.Equal(5, Schema("energy(m) = m * c^2"));
        Assert.Equal(5, Schema("rot(z) = z * i"));
        Assert.Equal(5, Schema("next(n) = nextprime(n)"));
        Assert.Equal(5, Schema("rest(w) = bmr w 180 cm 30 years male"));
        Assert.Equal(5, Schema("eco(v) = v in l/100km"));
        Assert.Equal(5, Schema("wave(a) = plot a * sin(x) from 0 to 6"));
        Assert.Equal(5, Schema("bars(v) = bar chart of v"));
        Assert.Equal(5, Schema("first(t) = column(t, 1)"));
        Assert.Equal(5, Schema("area(b) = integral(x^2, 0, b)", "rot(z) = z * i"));
    }

    [Theory]
    [InlineData("plot twist")]
    [InlineData("i think so")]
    [InlineData("bar chart monthly")]
    [InlineData("paint the fence")]
    public void ProseStaysProse(string source)
    {
        var result = Last(source); Assert.Null(result.Error); Assert.Equal("", result.Display);
    }
}
