using System.Globalization;
using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class ChemistryPracticalTests
{
    private static LineResult Last(string source)
    { var result = SheetEvaluator.Evaluate(source)[^1]; Assert.Null(result.Error); Assert.NotNull(result.Value); return result; }
    private static Rational Fraction(string text)
    { var p = text.Split('/'); return new(BigInteger.Parse(p[0],CultureInfo.InvariantCulture),p.Length==1?BigInteger.One:BigInteger.Parse(p[1],CultureInfo.InvariantCulture)); }
    public static IEnumerable<object[]> OracleCases()
    {
        using var s = typeof(ChemistryPracticalTests).Assembly.GetManifestResourceStream("Calc.ChemistryOracle")!;
        using var d = JsonDocument.Parse(s);
        return d.RootElement.GetProperty("cases").EnumerateArray().Select(row=>new object[]{row.GetRawText()}).ToArray();
    }
    [Theory, MemberData(nameof(OracleCases))]
    public void IndependentCompositionFractionAndDecimalOracle(string json)
    {
        using var d=JsonDocument.Parse(json);var row=d.RootElement;var result=Last(row.GetProperty("source").GetString()!);var value=result.Value!.Value;
        var expected=Fraction(row.GetProperty("canonical").GetString()!);
        switch(row.GetProperty("kind").GetString())
        {
            case "chemistry":
                Assert.Equal(expected,value.Exact.Rational);Assert.True(value.Number.IsApproximate);
                var e=Assert.Single(result.Explanation,step=>step.Chemistry is not null).Chemistry!;
                Assert.Equal(Fraction(row.GetProperty("gramsPerMole").GetString()!),e.NominalGramsPerMole);
                Assert.Equal(row.GetProperty("composition").EnumerateObject().OrderBy(x=>x.Name).Select(x=>(x.Name,x.Value.GetInt32())),e.Composition.OrderBy(x=>x.Symbol).Select(x=>(x.Symbol,x.Atoms)));
                break;
            case "grades":Assert.Equal(expected,value.Scalar);Assert.Equal(row.GetProperty("percent").GetBoolean(),value.IsPercentage);break;
            default:
                Assert.Equal(expected,value.Engineering.Original.Exact.Rational);Assert.Equal(row.GetProperty("display").GetString(),value.Display);
                Assert.Equal(value.Engineering.Original.Exact,Last(value.CopyText).Value!.Value.Engineering.Original.Exact);break;
        }
    }
    [Theory]
    [InlineData("molar mass H2SO4","≈ 98.072 g/mol")]
    [InlineData("molar mass Ca(OH)2","≈ 74.092 g/mol")]
    [InlineData("10 g H2O in mol","≈ 0.5551 mol")]
    [InlineData("2 mol NaCl in g","≈ 116.88 g")]
    [InlineData("moles(10 g,H2O)","≈ 0.5551 mol")]
    [InlineData("massOf(2 mol,NaCl)","≈ 116.88 g")]
    [InlineData("molarMass(CuSO4·5H2O)","≈ 249.677 g/mol")]
    [InlineData("molarMass(CuSO4.5H2O)","≈ 249.677 g/mol")]
    [InlineData("molar mass H₂O","≈ 18.015 g/mol")]
    [InlineData("molar mass K4[Fe(CN)6]","≈ 368.345 g/mol")]
    [InlineData("molar mass Co","≈ 58.933 g/mol")]
    [InlineData("molar mass CO","≈ 28.01 g/mol")]
    [InlineData("molarMass(Zr)","≈ 91.222 g/mol")]
    [InlineData("2 mol NaCl in kg","≈ 0.1169 kg")]
    [InlineData("grades 9 x3, 7 x2","8.2")]
    [InlineData("grades (8+1) x 3, 7 x 2","8.2")]
    [InlineData("weightedMean([90%,80%],[30%,70%])","83%")]
    [InlineData("grades 9 x0, 7 x2","7")]
    [InlineData("12345 in eng","12.345 × 10³")]
    [InlineData("4700 ohm in eng","4.7 kohm")]
    [InlineData("0.000012345 in eng","12.345 × 10⁻⁶")]
    [InlineData("engineering(-999999.5)","-1 × 10⁶")]
    [InlineData("engineering(0)","0")]
    [InlineData("engineering(1/3)","333.333 × 10⁻³")]
    [InlineData("engineering(sqrt(2))","1.41421")]
    [InlineData("x=123456789 in eng\nx-123456789","0")]
    [InlineData("1\n2\nsum in eng","3")]
    [InlineData("molarMass=4\nmolarMass(H2O)","≈ 18.015 g/mol")]
    [InlineData("principal=1200 in eng\nloan principal at 0% for 1 year","100")]
    [InlineData("places=2 in eng\n12.345 to places decimals","12.35")]
    [InlineData("f(x)=moles(x,H2O)\nf(10 g)","≈ 0.5551 mol")]
    [InlineData("f(x)=weightedMean(x,[3,2])\nf([9,7])","8.2")]
    public void PublishedAndTypedExamples(string source,string expected)=>Assert.Equal(expected,Last(source).Display);
    [Theory]
    [InlineData("molar mass h2o")][InlineData("molar mass Xx2")][InlineData("molar mass Tc")][InlineData("molarMass(Fe0)")]
    [InlineData("molarMass(Ca())")][InlineData("molarMass(Ca(OH]2)")][InlineData("molarMass(H2O·)")]
    [InlineData("molarMass(H2O+)")][InlineData("molarMass([13]C)")][InlineData("molarMass(D2O)")]
    [InlineData("molarMass(H1000001)")][InlineData("molarMass((H1000)1001)")][InlineData("molarMass(H500001O500000)")]
    [InlineData("moles(10,H2O)")][InlineData("moles(-1 g,H2O)")][InlineData("moles(10 USD,H2O)")]
    [InlineData("moles(1 m,H2O)")][InlineData("molarMass()")][InlineData("molarMass(H2O,2)")]
    [InlineData("weightedMean([],[])")][InlineData("weightedMean([1],[1,2])")][InlineData("weightedMean([1,2],[0,0])")]
    [InlineData("weightedMean([1,2],[1,-1])")][InlineData("weightedMean([1,2],[1%,1])")][InlineData("weightedMean([1%,2],[1,1])")]
    [InlineData("weightedMean([1 m],[1])")][InlineData("weightedMean([1],[1 m])")][InlineData("grades 9 x-1, 7 x2")]
    [InlineData("engineering(2 USD)")][InlineData("engineering(20 °C)")][InlineData("engineering(1,2)")][InlineData("engineering(1,1%)")]
    public void InvalidProfilesAndAmbiguousInputsFail(string source)=>Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);
    [Fact]
    public void CatalogCoversEveryElementAndNeverSubstitutesIsotopeMassNumbers()
    {
        Assert.Equal(118,AtomicWeightCatalog.Elements.Count);Assert.Equal(84,AtomicWeightCatalog.Elements.Count(x=>x.Weight is not null));
        foreach(var e in AtomicWeightCatalog.Elements.Where(x=>x.Weight is null))Assert.Contains("unavailable",SheetEvaluator.Evaluate("molarMass("+e.Symbol+")")[0].Error!);
        var evidence=Assert.Single(Last("molar mass H2O").Explanation,step=>step.Chemistry is not null).Chemistry!;
        Assert.Equal(AtomicWeightCatalog.RuleId,evidence.RuleId);Assert.Equal(new Rational(1,5000),evidence.Composition.Single(x=>x.Symbol=="H").QuotedUncertainty);
        Assert.Throws<NotSupportedException>(()=>((IList<ChemicalContribution>)evidence.Composition)[0]=evidence.Composition[0]);
    }
    [Fact]
    public void EngineeringCopyPreservesExactRadicalsApproximationAndLargeLiterals()
    {
        foreach(var input in new[]{"1/3","sqrt(2)+sqrt(3)","-123456789/7","10^1000","1/(10^1000)","12345 m","80%"})
        {var value=Last("engineering("+input+")").Value!.Value;var copy=Last(value.CopyText).Value!.Value;Assert.Equal(value.Engineering.Original.Exact,copy.Engineering.Original.Exact);Assert.Equal(value.Display,copy.Display);}
        var approximate=Last("engineering(1/3,1)").Value!.Value;
        Assert.True(Last(approximate.CopyText).Value!.Value.Engineering.Original.IsApproximate);
        Assert.Equal("≈ 2/3",Last(approximate.CopyText+"*2").Display); // retained original 1/3, ordinary arithmetic returns exact represented 2/3
    }
    [Fact]
    public void ChemicalConversionsAndFormulaExpansionHaveIndependentConservationIdentities()
    {
        foreach(var formula in new[]{"H2O","NaCl","Ca(OH)2","K4[Fe(CN)6]","CuSO4·5H2O"})
        {
            var a=Last("massOf(moles(123 g,"+formula+"),"+formula+")").Value!.Value;
            Assert.Equal(new Rational(123,1000),a.Exact.Rational);Assert.True(a.Number.IsApproximate);
        }
        Assert.Equal(Last("molarMass(Ca(OH)2)").Value!.Value.Exact,Last("molarMass(CaO2H2)").Value!.Value.Exact);
        Assert.Equal(Last("molarMass(CuSO4·5H2O)").Value!.Value.Exact,Last("molarMass(CuSO9H10)").Value!.Value.Exact);
    }
    [Fact]
    public void ContextCachesFunctionsAndNameCollisionsStayDeterministic()
    {
        var s=new SheetEvaluationSession();const string source="x=10 g\nmoles(x,H2O)\n12345 in eng\n7";
        s.EvaluateWithFunctions(source,FunctionLibrary.Empty,[]);var changed=s.EvaluateWithFunctions(source.Replace("10 g","20 g"),FunctionLibrary.Empty,[]);
        Assert.Equal("≈ 1.1102 mol",changed.Results[1].Display);Assert.Equal(1,s.LastStatistics.ParsedLines);Assert.Equal(2,s.LastStatistics.ReusedResults);
        var again=s.EvaluateWithFunctions(source.Replace("10 g","20 g"),FunctionLibrary.Empty,[],context:new(new DateOnly(2040,1,1),DateTimeOffset.UtcNow));
        Assert.Equal(4,s.LastStatistics.ReusedResults);Assert.False(again.UsesCurrentDate);Assert.False(again.UsesCurrentInstant);Assert.False(again.UsesCurrencyRates);
        var library=new FunctionLibrary([new("water",["x"],"moles(x,H2O)"),new("displayEng",["x"],"x in eng")]);
        Assert.Equal("≈ 0.5551 mol",s.EvaluateWithFunctions("water(10 g)",library,[]).Results[0].Display);
        Assert.Equal("12.345 × 10³",s.EvaluateWithFunctions("displayEng(12345)",library,[]).Results[0].Display);
        Assert.Equal("4",Last("grades=4\ngrades").Display);Assert.Equal("4",Last("molar mass=4\nmolar mass").Display);
        Assert.Throws<FormatException>(()=>new FunctionLibrary([new("weightedMean",["x"],"x")]));
    }
    [Fact]
    public void DepthSizeCancellationAndSharedResourceBoundsAreEnforced()
    {
        Assert.NotNull(SheetEvaluator.Evaluate("molarMass("+new string('(',17)+"H"+new string(')',17)+")")[0].Error);
        Assert.NotNull(SheetEvaluator.Evaluate("molarMass("+string.Concat(Enumerable.Repeat("H",513))+")")[0].Error);
        var values="["+string.Join(',',Enumerable.Repeat("1",1024))+"]";
        Assert.Equal("1",Last("x="+values+"\nweightedMean(x,x)").Display);
        Assert.Throws<SheetComputationLimitException>(()=>SheetEvaluator.Evaluate("x="+values+"\n"+string.Join('\n',Enumerable.Repeat("weightedMean(x,x)",150))));
        using var c=new CancellationTokenSource();c.Cancel();Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("molarMass(CuSO4·5H2O)",c.Token));
    }
    [Fact]
    public void ChemicalCaseEditsInvalidateFunctionReceiptsAndCachedResults()
    {
        var session = new SheetEvaluationSession();
        var initial = session.EvaluateWithFunctions("compound()=molarMass(Co)\ncompound()",FunctionLibrary.Empty,[]);
        Assert.Equal("≈ 58.933 g/mol",initial.Results[1].Display);
        var changed = session.EvaluateWithFunctions("compound()=molarMass(CO)\ncompound()",initial.Functions.Library,initial.Functions.Receipts);
        Assert.True(changed.Functions.HasChanges);Assert.NotEqual(initial.Functions.Library.Fingerprint,changed.Functions.Library.Fingerprint);
        Assert.Equal("≈ 28.01 g/mol",changed.Results[1].Display);
        var restored = session.EvaluateWithFunctions("compound()=molarMass(Co)\ncompound()",changed.Functions.Library,changed.Functions.Receipts);
        Assert.Equal("≈ 58.933 g/mol",restored.Results[1].Display);
    }
    [Fact]
    public void PrimitiveDispatchKeepsTheDocumentedFunctionDepthInsteadOfOverflowingTheStack()
    {
        var definitions = Enumerable.Range(0,33).Select(i=>new FunctionDefinition("depth"+i,["x"],i==0?"x":"depth"+(i-1)+"(x)")).ToArray();
        var library = new FunctionLibrary(definitions.Take(32)); var session = new SheetEvaluationSession();
        Assert.Equal("1",session.EvaluateWithFunctions("depth31(1)",library,[]).Results[0].Display);
        Assert.Contains("depth limit",Assert.Throws<ArithmeticException>(()=>new FunctionLibrary(definitions)).Message);
    }
    [Fact]
    public void DatedNestedFunctionConversionsUseSmallDispatchFramesAndTheSameContext()
    {
        var definitions = Enumerable.Range(0,25).Select(i=>new FunctionDefinition("dated"+i,["x"],i==0?"x USD in USD on 2024-01-01":"dated"+(i-1)+"(x) in USD on 2024-01-01")).ToArray();
        var result = new SheetEvaluationSession().EvaluateWithFunctions("dated24(1)",new FunctionLibrary(definitions),[],context:new(new DateOnly(2026,10,31)));
        Assert.Equal("1 USD",result.Results[0].Display);Assert.False(result.UsesCurrencyRates);
    }
}
