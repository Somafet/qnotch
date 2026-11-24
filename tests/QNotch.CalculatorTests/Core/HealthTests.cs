using Calc.Core;
using static Calc.Core.Tests.Practical;

namespace Calc.Core.Tests;

public class HealthTests
{
    [Theory]
    [InlineData("bmi(80 kg, 180 cm)", "24.7")]
    [InlineData("bmr 80 kg 180 cm 30 years male", "1780 kcal")]
    [InlineData("tdee 80 kg 180 cm 30 years male moderate", "2759 kcal")]
    [InlineData("tdee 80 kg 180 cm 30 years male moderate\nprev - 500 kcal", "2259 kcal")]
    [InlineData("hr zones age 30", "Z1 95–114 · Z2 114–133 · Z3 133–152 · Z4 152–171 · Z5 171–190")]
    [InlineData("hr zones max 185", "Z1 93–111 · Z2 111–130 · Z3 130–148 · Z4 148–167 · Z5 167–185")]
    public void PublishedReferenceExamples(string source, string display) => Assert.Equal(display, Last(source).Display);

    [Fact]
    public void BmiIsMassOverHeightSquaredWithExactValueKept()
    {
        var value = Value("bmi(80 kg, 180 cm)");
        Assert.Equal(new Rational(2000, 81), Canonical(value));
        Assert.Equal("24.7", value.Display);
        // Another route: converting the arguments through other units leaves the exact index unchanged.
        Assert.Equal(new Rational(2000, 81), Canonical(Value("bmi(80 kg in lb, 180 cm in in)")));
        Assert.Equal("22.9", Show("bmi(70 kg, 175 cm)"));
        Assert.Equal(Canonical(Value("bmi(70 kg, 175 cm)")), Canonical(Value("bmi(70 kg in lb, 1.75 m)")));
        // Composite stone/pound and foot/inch quantities against the exact definitions.
        var mass = R("12") * R("6.35029318") + R("9") * R("0.45359237"); var height = R("71") * R("0.0254");
        Assert.Equal(mass / (height * height), Canonical(Value("bmi(12 stone 9 lb, 5 ft 11 in)")));
    }
    [Theory]
    [InlineData("bmi(0 kg, 180 cm)")][InlineData("bmi(80 kg, 0 cm)")][InlineData("bmi(-80 kg, 180 cm)")][InlineData("bmi(80 kg, -1 m)")]
    [InlineData("bmi(1001 kg, 180 cm)")][InlineData("bmi(80 kg, 3.01 m)")][InlineData("bmi(80, 180)")][InlineData("bmi(80 cm, 180 kg)")][InlineData("bmi(80 kg)")]
    [InlineData("bmi(80 kg, 180 cm, 3)")][InlineData("bmi(80 %, 180 cm)")]
    public void BmiRejectsNonpositiveImplausibleAndUntypedInputs(string source) => Assert.NotNull(Last(source).Error);

    [Fact]
    public void BmiCarriesNoCategoryAndItsExplanationStatesTheFormula()
    {
        var result = Last("bmi(80 kg, 180 cm)");
        Assert.DoesNotContain("overweight", result.Display + result.Explanation[^1].Assumption, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("no category", result.Explanation[^1].Assumption!, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("mass (kg) / height (m)^2", result.Explanation[^1].Assumption!);
    }

    [Fact]
    public void MifflinStJeorMatchesAnIndependentDecimalComputation()
    {
        // 10 * 80 + 6.25 * 180 - 5 * 30 + 5 = 1780 and the female constant is -161.
        Assert.Equal(R("1780") * R("4184"), Canonical(Value("bmr 80 kg 180 cm 30 years male")));
        Assert.Equal(R("1780") * R("4184") - R("166") * R("4184"), Canonical(Value("bmr 80 kg 180 cm 30 years female")));
        // 65 kg, 165 cm, 40 years, female: 650 + 1031.25 - 200 - 161 = 1320.25 kcal, displayed to whole kcal.
        var woman = Value("bmr 65 kg 165 cm 40 years female");
        Assert.Equal(R("1320.25"), InOwnUnit(woman)); Assert.Equal("1320 kcal", woman.Display);
        // 176 lb and 5 ft 11 in with the exact pound and inch definitions.
        var imperial = Value("bmr 176 lb 5 ft 11 in 30 years male");
        Assert.Equal(R("10") * R("176") * R("0.45359237") + R("6.25") * R("71") * R("2.54") - R("150") + R("5"), InOwnUnit(imperial));
        Assert.Equal(R("10") * R("176.37") * R("0.45359237") + R("6.25") * R("180") - R("150") + R("5"), InOwnUnit(Value("bmr 176.37 lb 180 cm 30 years male")));
    }
    [Fact]
    public void UnitsAreInterchangeableAndAgeUnitWordIsOptional()
    {
        var metric = Canonical(Value("bmr 80 kg 180 cm 30 years male"));
        Assert.Equal(metric, Canonical(Value("bmr 80000 g 1.8 m 30 yr male")));
        Assert.Equal(metric, Canonical(Value("bmr 80 kg 180 cm 30 male")));
        Assert.Equal(metric, Canonical(Value("bmr (80 kg in lb) (180 cm in in) 30 years male")));
        Assert.Equal(metric, Canonical(Value("w = 80 kg\nh = 180 cm\nbmr w h 30 years male")));
        Assert.Equal(metric, Canonical(Value("bmr 80 kg 1 m 80 cm 30 years male")));
    }
    [Theory]
    [InlineData("sedentary", "1.2")][InlineData("light", "1.375")][InlineData("moderate", "1.55")][InlineData("active", "1.725")][InlineData("very active", "1.9")]
    public void ActivityMultipliersScaleTheRestingRateExactly(string level, string factor)
    {
        var tdee = Value("tdee 80 kg 180 cm 30 years male " + level);
        Assert.Equal(R("1780") * R(factor), InOwnUnit(tdee));
        Assert.Equal("kcal", tdee.Number.Unit!.Symbol);
    }
    [Fact]
    public void RoundingIsDisplayOnlyAndTheExactValueFeedsLaterLines()
    {
        // 1780 * 1.375 = 2447.5 shows as 2448 kcal yet later arithmetic keeps the half.
        var lines = SheetEvaluator.Evaluate("tdee 80 kg 180 cm 30 years male light\nprev - 0.5 kcal\nprev * 2", default, Clock);
        Assert.Equal("2448 kcal", lines[0].Display); Assert.Equal("2447 kcal", lines[1].Display); Assert.Equal("4894 kcal", lines[2].Display);
        Assert.Equal("2447.5 kcal", Show("tdee 80 kg 180 cm 30 years male light to 1 decimals"));
        Assert.Equal("2447500 cal", Show("tdee 80 kg 180 cm 30 years male light in cal"));
        Assert.Equal("2759 kcal", Show("tdee 80 kg 180 cm 30 years male moderate to 0 decimals"));
    }
    [Fact]
    public void KilocalorieQuantityConvertsAndStatesTheDailySemantics()
    {
        Assert.Equal(R("1780") * R("4.184"), InOwnUnit(Value("bmr 80 kg 180 cm 30 years male in kJ")));
        var step = Last("bmr 80 kg 180 cm 30 years male").Explanation[^1];
        Assert.Contains("kilocalories per day", step.Assumption!); Assert.Contains("Mifflin-St Jeor", step.Assumption!); Assert.Contains("not medical advice", step.Assumption!);
        Assert.Contains("1.55", Last("tdee 80 kg 180 cm 30 years male moderate").Explanation[^1].Assumption!);
    }
    [Theory]
    [InlineData("bmr 0 kg 180 cm 30 years male")][InlineData("bmr 80 kg 0 cm 30 years male")][InlineData("bmr 80 kg 180 cm 0 years male")][InlineData("bmr -80 kg 180 cm 30 years male")]
    [InlineData("bmr 80 kg 180 cm -3 years male")][InlineData("bmr 80 kg 180 cm 151 years male")][InlineData("bmr 1001 kg 180 cm 30 years male")][InlineData("bmr 80 kg 4 m 30 years male")]
    [InlineData("bmr 80 180 30 years male")][InlineData("bmr 80 cm 180 kg 30 years male")][InlineData("bmr 0.5 kg 50 cm 100 years female")]
    public void BodyInputsAreBounded(string source) => Assert.NotNull(Last(source).Error);

    private static int[] Expected(int maximum) => Enumerable.Range(5, 6).Select(tenths => (2 * maximum * tenths + 10) / 20).ToArray();
    [Fact]
    public void HeartRateZonesRoundEachBoundaryHalfUpAndShareEdges()
    {
        // Independent integer route: edge = floor(max * k / 10 + 1/2) for k = 5..10; reproduces both published lines.
        for (var age = 1; age <= 120; age++)
        {
            var zones = Value("hr zones age " + age).Practical.Zones; var edges = Expected(220 - age);
            Assert.Equal(5, zones.Count);
            for (var i = 0; i < 5; i++) { Assert.Equal(i + 1, zones[i].Number); Assert.Equal(edges[i], zones[i].Low); Assert.Equal(edges[i + 1], zones[i].High); }
        }
        foreach (var maximum in new[] { 150, 171, 185, 199, 200, 207 })
        {
            var zones = Value("hr zones max " + maximum).Practical.Zones; var edges = Expected(maximum);
            Assert.Equal(edges, zones.Select(zone => zone.Low).Append(zones[^1].High).ToArray());
            Assert.Equal(maximum, zones[^1].High);
        }
        Assert.Equal("Z1 93–111 · Z2 111–130 · Z3 130–148 · Z4 148–167 · Z5 167–185", Show("hr zones max 185 bpm"));
        Assert.Equal(Show("hr zones age 30"), Show("hr zones max 190"));
        Assert.Equal(Show("hr zones age 30"), Show("hr zones age 30 years"));
        Assert.Equal(Show("hr zones age 30"), Show("hr zones age (25 + 5)"));
    }
    [Fact]
    public void HeartRateZonesCopyExplainAndStayOutOfArithmeticAndTotals()
    {
        var result = Last("hr zones age 30");
        Assert.Equal(SheetValueKind.Practical, result.Value!.Value.Kind); Assert.Equal(result.Display, result.Value.Value.CopyText);
        Assert.Contains("220 - age", result.Explanation[^1].Assumption!); Assert.Contains("50-60%", result.Explanation[^1].Assumption!); Assert.Contains("halves up", result.Explanation[^1].Assumption!);
        var lines = SheetEvaluator.Evaluate("10\nhr zones age 30\n20\nsum", default, Clock);
        Assert.Equal("30", lines[3].Display); Assert.Null(lines[3].Error);
        Assert.NotNull(Last("z = hr zones age 30\nz + 1").Error); Assert.NotNull(Last("hr zones age 30\nprev * 2").Error);
        Assert.Equal("30 kg", Show("hr zones age 30 kg"));
        Assert.Equal("15", SheetEvaluator.Evaluate("hr zones age 30\n10\n20\naverage", default, Clock)[3].Display);
    }
    [Theory]
    [InlineData("hr zones age 0")][InlineData("hr zones age 151")][InlineData("hr zones age 221")][InlineData("hr zones max 0")][InlineData("hr zones max 301")][InlineData("hr zones max -5")]
    [InlineData("hr zones")][InlineData("hr zones age")][InlineData("hr zones age 30 max 190")]
    public void HeartRateZoneInputsAreBounded(string source) => Assert.Null(Last(source).Value);
    [Fact]
    public void HeartRateZoneBoundsAreInclusive()
    {
        Assert.Equal("Z1 35–42 · Z2 42–49 · Z3 49–56 · Z4 56–63 · Z5 63–70", Show("hr zones age 150"));
        Assert.Equal("Z1 150–180 · Z2 180–210 · Z3 210–240 · Z4 240–270 · Z5 270–300", Show("hr zones max 300"));
    }

    [Theory]
    [InlineData("bmr")][InlineData("tdee")][InlineData("hr")][InlineData("hr zones")][InlineData("bmr and tdee are estimates")][InlineData("my bmr today")][InlineData("hr zones are useful")]
    public void WordsKeepTheirProseMeaning(string source)
    {
        var result = SheetEvaluator.Evaluate(source, default, Clock)[0];
        Assert.Null(result.Value); Assert.Null(result.Error);
    }
    [Fact]
    public void LabelsAndVariablesWinOverTheSentenceHeads()
    {
        Assert.Equal("1780", Show("bmr 1780"));
        Assert.Equal("60", Show("hr 60"));
        Assert.Equal("10", Show("bmr = 5\nbmr * 2"));
        Assert.Equal("120", Show("hr = 60\nhr * 2"));
        Assert.Equal("6", Show("tdee = 3\ntdee + tdee"));
        // The sentence is not attempted when its head is a user variable; the rest then has no meaning.
        Assert.NotNull(Last("bmr = 5\nbmr 80 kg 180 cm 30 years male").Error);
        // A variable that shares a keyword inside the sentence does not disturb it.
        Assert.Equal("1780 kcal", Show("male = 2\nbmr 80 kg 180 cm 30 years male"));
        Assert.Equal("Z1 95–114 · Z2 114–133 · Z3 133–152 · Z4 152–171 · Z5 171–190", Show("zones = 5\nhr zones age 30"));
    }
    [Fact]
    public void SavedFunctionsParseCanonicalizeAndReload()
    {
        var update = FunctionUpdate.Prepare("body(w, h) = bmi(w, h)\nrest(w, h, a) = bmr w h a years female\nburn(w, h, a) = tdee w h a years male active\nzones(a) = hr zones age a", FunctionLibrary.Empty, []);
        Assert.Equal(FunctionLibrary.LatestCatalogVersion, update.Library.MinimumCatalogVersion);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("body(80 kg, 180 cm)\nrest(65 kg, 165 cm, 40)\nburn(80 kg, 180 cm, 30)\nzones(30)", update.Library, [], context: Clock).Results;
        Assert.Equal(["24.7", "1320 kcal", "3071 kcal", "Z1 95–114 · Z2 114–133 · Z3 133–152 · Z4 152–171 · Z5 171–190"], results.Select(r => r.Display));
        Assert.Equal(update.Library.Fingerprint, new FunctionLibrary(update.Library.Definitions).Fingerprint);
        var upper = FunctionUpdate.Prepare("body(w, h) = BMI(w, h)", FunctionLibrary.Empty, []);
        Assert.False(FunctionUpdate.Prepare("Body(W, H) = bmi(W, H)", upper.Library, upper.Receipts).HasChanges);
        Assert.Equal(1, new FunctionLibrary([new("plain", ["v"], "v + 1")]).MinimumCatalogVersion);
        Assert.Throws<FormatException>(() => new FunctionLibrary([new("bmi", ["a", "b"], "a + b")]));
    }
}
