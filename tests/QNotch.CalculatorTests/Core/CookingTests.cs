using Calc.Core;
using static Calc.Core.Tests.Practical;

namespace Calc.Core.Tests;

public class CookingTests
{
    [Theory]
    [InlineData("2.5 cups in ml to 2 decimals", "591.47 mL")]
    [InlineData("250 g * 6 / 4", "375 g")]
    [InlineData("scale 250 g from 4 to 6 servings", "375 g")]
    public void PublishedReferenceExamples(string source, string display) => Assert.Equal(display, Show(source));

    [Fact]
    public void CupToMillilitreIsExactAndFlourIsOneTwentyFiveGrams()
    {
        // 1 US customary cup = 236.5882365 mL exactly; the unit catalog already holds it, the sentence code reads it back.
        Assert.Equal(R("591.47059125"), InOwnUnit(Value("2.5 cups in ml")));
        Assert.Equal("591.47059125 mL", Show("2.5 cups in ml"));
        var flour = Value("1 cup flour in g");
        Assert.Equal(R("125"), InOwnUnit(flour)); Assert.Equal("g", flour.Number.Unit!.Symbol);
        Assert.True(flour.Number.IsApproximate); Assert.Equal("≈ 125 g", flour.Display);
        Assert.Equal("1 cup", Show("1 cup in cup")); Assert.Equal("16 tbsp", Show("1 cup in tbsp")); Assert.Equal("1 tbsp", Show("3 tsp in tbsp"));
    }
    [Fact]
    public void DensityIsRecomputedBySecondRouteForOtherVolumesAndMasses()
    {
        // grams = volume / 236.5882365 mL * 125 g, with the rational arithmetic done here rather than by the evaluator.
        var cupMl = R("236.5882365");
        Assert.Equal(R("100") * R("125") / cupMl, InOwnUnit(Value("100 ml flour in g")));
        Assert.Equal(R("125"), InOwnUnit(Value("16 tbsp flour in g")));
        Assert.Equal(R("125"), InOwnUnit(Value("48 tsp flour in g")));
        Assert.Equal(R("62.5"), InOwnUnit(Value("0.5 cup flour in g")));
        Assert.Equal(R("250"), InOwnUnit(Value("2 cups flour in g")));
        Assert.Equal(R("125"), InOwnUnit(Value("236.5882365 ml flour in g")));
        Assert.Equal(R("62.5"), InOwnUnit(Value("4 floz flour in g")));
    }
    [Fact]
    public void MassToVolumeIsTheInverse()
    {
        Assert.Equal(R("1"), InOwnUnit(Value("125 g flour in cups")));
        Assert.Equal(R("16"), InOwnUnit(Value("125 g flour in tbsp")));
        Assert.Equal(R("236.5882365"), InOwnUnit(Value("125 g flour in ml")));
        Assert.Equal(R("1"), InOwnUnit(Value("0.125 kg flour in cup")));
        Assert.Equal(R("0.24"), InOwnUnit(Value("30 g flour in cup")));
        foreach (var ingredient in IngredientCatalog.Ingredients)
        {
            var name = ingredient.Names[0];
            Assert.Equal(ingredient.GramsPerCup, InOwnUnit(Value("1 cup " + name + " in g")));
            Assert.Equal(R("1"), InOwnUnit(Value(ingredient.GramsPerCup + " g " + name + " in cup")));
            Assert.Equal(R("2") * ingredient.GramsPerCup / R("1000"), InOwnUnit(Value("2 cups " + name + " in kg")));
        }
    }
    [Fact]
    public void CatalogHoldsAboutThirtyPinnedIngredientsWithAnExplicitSourceEach()
    {
        var items = IngredientCatalog.Ingredients;
        Assert.InRange(items.Count, 30, 40); Assert.Equal(items.Count, items.Select(item => item.Id).Distinct().Count());
        Assert.All(items, item => { Assert.False(string.IsNullOrWhiteSpace(item.Source)); Assert.True(item.GramsPerCup.Numerator.Sign > 0); Assert.Contains(item.Id, item.Names); });
        var flour = items.Single(item => item.Id == "flour");
        Assert.Equal(R("125"), flour.GramsPerCup); Assert.Contains("fdcId 168894", flour.Source); Assert.Equal("", flour.Note);
        Assert.All(items, item => Assert.StartsWith("USDA FoodData Central SR Legacy fdcId ", item.Source));
        Assert.Contains("USDA", IngredientCatalog.Dataset); Assert.Contains("estimate", IngredientCatalog.Basis, StringComparison.OrdinalIgnoreCase);
    }
    [Fact]
    public void EveryUsdaValueMatchesTheRetainedSourceExtract()
    {
        using var stream = typeof(CookingTests).Assembly.GetManifestResourceStream("Calc.IngredientUsda")!;
        using var reader = new StreamReader(stream);
        var rows = new List<string[]>();
        for (var line = reader.ReadLine(); line is not null; line = reader.ReadLine()) if (line.Length > 0) rows.Add(CsvFields(line));
        Assert.Equal(["id", "fdcId", "description", "portion", "gramWeight"], rows[0]);
        Assert.Equal(IngredientCatalog.Ingredients.Count, rows.Count - 1);
        foreach (var row in rows.Skip(1))
        {
            var item = IngredientCatalog.Ingredients.Single(entry => entry.Id == row[0]);
            Assert.Equal(R(row[4]), item.GramsPerCup); Assert.Contains("fdcId " + row[1] + ":", item.Source); Assert.Contains(row[2], item.Source);
        }
    }
    private static string[] CsvFields(string line)
    {
        var fields = new List<string>(); var current = new System.Text.StringBuilder(); var quoted = false;
        for (var i = 0; i < line.Length; i++)
        {
            if (line[i] == '"') { if (quoted && i + 1 < line.Length && line[i + 1] == '"') { current.Append('"'); i++; } else quoted = !quoted; }
            else if (line[i] == ',' && !quoted) { fields.Add(current.ToString()); current.Clear(); }
            else current.Append(line[i]);
        }
        fields.Add(current.ToString()); return fields.ToArray();
    }
    [Fact]
    public void IngredientNamesAreCaseInsensitiveMultiWordAndHyphenTolerant()
    {
        Assert.Equal(R("220"), InOwnUnit(Value("1 cup brown sugar in g")));
        Assert.Equal(R("200"), InOwnUnit(Value("1 cup sugar in g")));
        Assert.Equal(R("125"), InOwnUnit(Value("1 cup all purpose flour in g")));
        Assert.Equal(R("125"), InOwnUnit(Value("1 cup all-purpose flour in g")));
        Assert.Equal(R("125"), InOwnUnit(Value("1 cup of flour in g")));
        Assert.Equal(R("125"), InOwnUnit(Value("1 cup Flour to g")));
        Assert.Equal(R("137"), InOwnUnit(Value("1 cup bread flour in g")));
        Assert.Equal(R("216"), InOwnUnit(Value("1 cup olive oil in g")));
        Assert.Equal(R("218"), InOwnUnit(Value("1 cup oil in g")));
        Assert.Equal(R("0.25"), InOwnUnit(Value("2 cups flour in kg")));
        Assert.Equal(R("250"), InOwnUnit(Value("(1 + 1) cups flour in g")));
        Assert.Equal(R("125"), InOwnUnit(Value("cupful = 1 cup\ncupful flour in g")));
    }
    [Fact]
    public void ResultsAreApproximateEstimatesWhoseExplanationNamesTheDensityAndSource()
    {
        var step = Last("1 cup brown sugar in g").Explanation[^1];
        Assert.Equal("ingredient conversion", step.Operation);
        Assert.Contains("brown sugar = 220 g per US cup", step.Assumption!); Assert.Contains("236.5882365 mL", step.Assumption!);
        Assert.Contains("fdcId 168833", step.Assumption!); Assert.Contains("brand, moisture, sifting and packing", step.Assumption!);
        Assert.StartsWith("Approximate input/result;", step.Assumption!);
        Assert.Contains("fdcId 168894", Last("1 cup flour in g").Explanation[^1].Assumption!);
        Assert.Equal("≈ 7.81 g", Show("1 tbsp flour in g"));
        Assert.Equal("≈ 7.81 g", Show("1 tbsp flour in g to 2 decimals"));
    }
    [Fact]
    public void UnknownIngredientIsAnErrorNamingIt()
    {
        var result = Last("1 cup unobtainium in g");
        Assert.Equal("Unknown ingredient: unobtainium", result.Error);
        Assert.Equal("Unknown ingredient: dragon fruit", Last("2 cups dragon fruit in g").Error);
        Assert.Equal("Unknown ingredient: stardust", Last("100 g stardust in cups").Error);
        // Without the opposite-dimension target the words keep their ordinary (unsupported) meaning rather than becoming an ingredient error.
        Assert.NotEqual("Unknown ingredient: unobtainium", Last("1 cup unobtainium").Error);
        Assert.NotEqual("Unknown ingredient: sugar", Last("1 cup sugar").Error);
        Assert.Null(Last("1 cup flour").Value);
    }
    [Fact]
    public void SameDimensionTargetsUseThePlainUnitConversion()
    {
        var millilitres = Last("1 cup flour in ml");
        Assert.Equal(R("236.5882365"), InOwnUnit(millilitres.Value!.Value));
        Assert.False(millilitres.Value.Value.Number.IsApproximate); Assert.Contains("density not used", millilitres.Explanation[^1].Assumption!);
        Assert.Equal("1 cup", Show("1 cup flour in cups"));
        Assert.Equal(R("0.1") / R("0.028349523125"), InOwnUnit(Value("100 g flour in oz")));
    }
    [Theory]
    [InlineData("1 cup flour in m")][InlineData("1 cup flour in s")][InlineData("1 m flour in g")][InlineData("1 s flour in g")][InlineData("5 flour in g")][InlineData("1 degC flour in g")][InlineData("1 cup flour in 5")]
    public void OnlyVolumeAndMassMeasuresConvert(string source) => Assert.Null(Last(source).Value);
    [Fact]
    public void NegationAppliesAfterTheConversion() => Assert.Equal("≈ -125 g", Show("-1 cup flour in g"));
    [Fact]
    public void VariablesAndProseKeepTheirMeaning()
    {
        Assert.NotNull(Last("flour = 3\n1 cup flour in g").Error);
        Assert.Equal("3", Show("flour = 3\nflour"));
        Assert.Equal("200", Show("sugar = 200\nsugar"));
        Assert.Equal("5", Show("water = 5\nwater"));
        Assert.Equal("3 cup", Show("3 cups"));
        Assert.Null(Last("a cup of flour is a lot").Value);
        Assert.Equal("2 cup", Show("Flour for the cake 2 cups"));
    }
    [Fact]
    public void ExistingCupTablespoonAndTeaspoonUnitsAreUntouched()
    {
        Assert.Equal(R("236.5882365"), InOwnUnit(Value("1 cup in ml")));
        Assert.Equal(R("14.78676478125"), InOwnUnit(Value("1 tbsp in ml")));
        Assert.Equal(R("4.92892159375"), InOwnUnit(Value("1 tsp in ml")));
        Assert.Equal("3 tsp", Show("1 tbsp in tsp"));
        Assert.Equal("0.5 cup", Show("8 tbsp in cups"));
    }
    [Fact]
    public void ServingScalingIsLinearAndRejectsNonpositiveServings()
    {
        Assert.Equal(R("375"), InOwnUnit(Value("scale 250 g from 4 to 6 servings")));
        Assert.Equal(R("375"), InOwnUnit(Value("scale 250 g from 4 to 6")));
        Assert.Equal(R("1"), InOwnUnit(Value("scale 2 cups from 8 to 4 portions")));
        Assert.Equal(Show("250 g * 6 / 4"), Show("scale 250 g from 4 to 6 servings"));
        Assert.Equal("1.5 cup", Show("base = 4\nguests = 6\nscale 1 cup from base to guests"));
        Assert.Equal("2.5", Show("scale 1 from 2 to 5"));
        Assert.Equal("62.5%", Show("scale 50% from 4 to 5"));
        Assert.Equal("≈ 187.5 g", Show("scale (1 cup flour in g) from 4 to 6 servings"));
        var step = Last("scale 250 g from 4 to 6 servings").Explanation[^1];
        Assert.Contains("6/4", step.Assumption!); Assert.Contains("linearly", step.Assumption!);
        Assert.NotNull(Last("scale 250 g from 0 to 6 servings").Error); Assert.NotNull(Last("scale 250 g from 4 to 0 servings").Error); Assert.NotNull(Last("scale 250 g from 4 to -2 servings").Error);
        Assert.NotNull(Last("scale 250 g from 4 kg to 6 servings").Error);
    }
    [Theory]
    [InlineData("scale")][InlineData("scale the recipe")][InlineData("scale up")]
    public void ScaleAsProseStaysProse(string source)
    {
        var result = Last(source);
        Assert.Null(result.Value); Assert.Null(result.Error);
    }
    [Theory]
    [InlineData("scale 250 g", "250 g")]
    public void ScaleBeforeAQuantityIsALabel(string source, string display) => Assert.Equal(display, Show(source));
    [Fact]
    public void ScaleAsAVariableAndAsLabelStillWork()
    {
        Assert.Equal("6", Show("scale = 3\nscale * 2"));
        Assert.Equal("250 g", Show("scale 250 g"));
        Assert.NotNull(Last("scale = 3\nscale 250 g from 4 to 6 servings").Error);
    }
    [Fact]
    public void SavedFunctionsParseCanonicalizeAndReload()
    {
        var update = FunctionUpdate.Prepare("grams(v) = v flour in g\ncups(m) = m sugar in cups\nbatch(a, n) = scale a from 4 to n servings", FunctionLibrary.Empty, []);
        Assert.Equal(FunctionLibrary.LatestCatalogVersion, update.Library.MinimumCatalogVersion);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("grams(1 cup)\ncups(200 g)\nbatch(250 g, 6)", update.Library, [], context: Clock).Results;
        Assert.Equal(["≈ 125 g", "≈ 1 cup", "375 g"], results.Select(r => r.Display));
        Assert.Equal(update.Library.Fingerprint, new FunctionLibrary(update.Library.Definitions).Fingerprint);
        var changed = FunctionUpdate.Prepare("grams(v) = v sugar in g", update.Library, update.Receipts);
        Assert.True(changed.HasChanges);
        Assert.Equal("≈ 200 g", new SheetEvaluationSession().EvaluateWithFunctions("grams(1 cup)", changed.Library, [], context: Clock).Results[0].Display);
    }
    [Fact]
    public void IngredientResultsAddAndTotalAsMeasuredQuantities()
    {
        var lines = SheetEvaluator.Evaluate("1 cup flour in g\n1 cup sugar in g\nsum", default, Clock);
        Assert.Equal(R("325"), InOwnUnit(lines[2].Value!.Value)); Assert.Contains("g", lines[2].Display);
    }
}
