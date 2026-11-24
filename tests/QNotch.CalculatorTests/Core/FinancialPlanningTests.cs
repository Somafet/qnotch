using System.Globalization;
using System.Numerics;
using Calc.Core;

namespace Calc.Core.Tests;

public class FinancialPlanningTests
{
    private static LineResult Last(string source, EvaluationContext? context=null)
    { var result=SheetEvaluator.Evaluate(source,context:context)[^1]; Assert.Null(result.Error); return result; }
    private static Rational Magnitude(LineResult result) => result.Value!.Value.Kind==SheetValueKind.Money ? result.Value.Value.Money.Magnitude.Scalar : result.Value.Value.Scalar;
    private static double Real(Rational value) => (double)value.Numerator/(double)value.Denominator;
    private static string Explain(LineResult value) => string.Join("\n",value.Explanation.Select(step=>step.Assumption));

    [Theory]
    [InlineData("roi(1000,1500)","50%")]
    [InlineData("ROI(1000 EUR,1500 EUR)","50%")]
    [InlineData("roi(100,0)","-100%")]
    [InlineData("cagr(1000,2500,5 years)","≈ 20.1124%")]
    [InlineData("cagr(100,144,2)","20%")]
    [InlineData("cagr(100,200,2 years)","41.4214%")]
    [InlineData("cagr(100,121,6 months)","46.41%")]
    [InlineData("cagr(100,121,1/2)","46.41%")]
    [InlineData("cagr(100,0,5)","-100%")]
    [InlineData("cagr(100,80,1)","-20%")]
    [InlineData("realreturn(5%,3%)","1.9417%")]
    [InlineData("5% minus 3% inflation","1.9417%")]
    [InlineData("5% - 3% inflation","1.9417%")]
    [InlineData("realreturn(-100%,5%)","-100%")]
    [InlineData("fire(40000)","1000000")]
    [InlineData("fire 40k/year","1000000")]
    [InlineData("fire 3000/month at 4%","900000")]
    [InlineData("fire 3000 EUR per month at 3%","1200000 EUR")]
    [InlineData("fire $1000 monthly","300000 USD")]
    [InlineData("fire 1000 yearly at 100%","1000")]
    [InlineData("fire(0,4%)","0")]
    [InlineData("breakeven(5000,50,30)","250")]
    [InlineData("break even fixed 5000, price 50, cost 30","250")]
    [InlineData("breakeven(10 EUR,8 EUR,5 EUR)","3.3333")]
    [InlineData("breakeven(0,0,0)","0")]
    [InlineData("depreciate 10000 over 5 years","2000")]
    [InlineData("depreciate 10000 EUR over 5 years salvage 1000 EUR","1800 EUR")]
    [InlineData("depreciate 1200 over 12 months","100")]
    [InlineData("sln(30000,7500,10)","2250")]
    [InlineData("sln(100,0,2.5)","40")]
    [InlineData("ddb(10000,1000,5,1)","4000")]
    [InlineData("ddb(2400,300,10,2,1.5)","306")]
    [InlineData("ddb(2400,300,10,10)","22.1225")]
    [InlineData("ddb(2400,300,120,1)","40")]
    [InlineData("ddb(100,20,2,2,10)","0")]
    [InlineData("syd(10000,1000,5,1)","3000")]
    [InlineData("syd(30000,7500,10,1)","4090.9091")]
    [InlineData("syd(30000,7500,10,10)","409.0909")]
    [InlineData("f(x)=fire x/month at 4%\nf(3000)","900000")]
    [InlineData("f(x)=depreciate x over 5 years\nf(10000)","2000")]
    [InlineData("fire=12\nfire+2","14")]
    [InlineData("fire budget=12\nfire budget+2","14")]
    [InlineData("(fire 3000/month at 4%)/1000","900")]
    public void PublicExamplesAndTypedBoundaries(string source,string expected) => Assert.Equal(expected,Last(source).Display);

    [Theory]
    [InlineData("roi(0,100)")][InlineData("roi(-100,100)")][InlineData("roi(100,-1)")]
    [InlineData("cagr(100,110,0)")][InlineData("cagr(100,110,1201 months)")]
    [InlineData("cagr(100,110,1 day)")][InlineData("cagr(100,110,1/100)")]
    [InlineData("cagr(100,110,1 year + 1 day)")]
    [InlineData("realreturn(5%,-100%)")][InlineData("realreturn(-101%,3%)")]
    [InlineData("fire(100,0)")][InlineData("fire(-1)")][InlineData("fire(100,101%)")]
    [InlineData("fire 3000")][InlineData("fire 3000/day")]
    [InlineData("breakeven(100,20,20)")][InlineData("breakeven(100,10,20)")]
    [InlineData("breakeven(-1,10,5)")][InlineData("breakeven(100,-10,5)")]
    [InlineData("sln(100,101,5)")][InlineData("sln(100,0,0)")][InlineData("sln(100,0,1201)")]
    [InlineData("ddb(100,10,5,6)")][InlineData("ddb(100,10,5,0)")]
    [InlineData("ddb(100,10,5,1,-1)")][InlineData("ddb(100,10,5.5,1)")]
    [InlineData("syd(100,10,5,1.5)")][InlineData("syd(100,10,5,6)")]
    [InlineData("fire(100 EUR,4 EUR)")][InlineData("roi(100 EUR,110)")]
    [InlineData("sln(100 m,0,5)")][InlineData("cagr(100,110)")]
    public void InvalidInputsAreExplicit(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);

    [Fact]
    public void ExactReturnAndQuadraticRootsSurviveDependentArithmetic()
    {
        Assert.Equal(new Rational(2,103),Magnitude(Last("realreturn(5%,3%)")));
        Assert.Equal(new Rational(1,3),Magnitude(Last("r=roi(3,4)\nr")));
        Assert.Equal("4",Last("r=cagr(1,2,2)\n(r+100%)^2*2").Display);
        Assert.False(Last("cagr(1,2,2)").Value!.Value.Number.IsApproximate);
        Assert.Contains("whole-unit coverage threshold 4",Explain(Last("breakeven(10,8,5)")));
        Assert.Contains("no automatic straight-line switch",Explain(Last("ddb(100,0,5,5)")));
        Assert.Contains("annualized by 12",Explain(Last("fire 3000/month at 4%")));
    }

    [Fact]
    public void SeededExactGrowthCasesInvertTheForwardCompoundEquation()
    {
        var random=new Random(5831);
        for(var i=0;i<60;i++)
        {
            var numerator=random.Next(1,20); var denominator=random.Next(1,20); var years=random.Next(1,16);
            var growth=new Rational(numerator,denominator);
            var ending=new Rational(BigInteger.Pow(numerator,years),BigInteger.Pow(denominator,years));
            var answer=Last($"cagr(1,({ending}),{years})");
            Assert.Equal(growth-new Rational(1,1),Magnitude(answer));
            Assert.False(answer.Value!.Value.Number.IsApproximate);
        }
    }

    [Fact]
    public void NonrationalCagrCertificateEnclosesAnIndependentForwardPowerCrossing()
    {
        foreach(var (start,end,months) in new[]{(1000,2500,60),(1000,300,84),(100,999,119),(100,101,1199)})
        {
            var answer=Last($"cagr({start},{end},{months} months)");
            var evidence=Assert.Single(answer.Explanation,step=>step.Growth is not null).Growth!;
            Assert.Equal(new Rational(months,12),evidence.Years);
            var interval=Assert.Single(evidence.Root!.Roots);
            var expected=Math.Pow((double)end/start,12d/months)-1;
            Assert.InRange(Math.Abs(Real(interval.LowerRate)-expected),0,1e-12);
            Assert.InRange(Math.Abs(Real(interval.UpperRate)-expected),0,1e-12);
            // Exact rational endpoint powers verify the forward equation independently of IRR's discount polynomial.
            static BigInteger ForwardSign(Rational r,int degree,Rational target)
            { return BigInteger.Pow(r.Numerator+r.Denominator,degree)*target.Denominator-BigInteger.Pow(r.Denominator,degree)*target.Numerator; }
            Assert.True(ForwardSign(interval.LowerRate,evidence.RootDegree,evidence.PoweredRatio).Sign<=0);
            Assert.True(ForwardSign(interval.UpperRate,evidence.RootDegree,evidence.PoweredRatio).Sign>=0);
        }
    }

    [Fact]
    public void DepreciationSchedulesConserveBasisAndRespectSalvage()
    {
        var random=new Random(8374);
        for(var trial=0;trial<25;trial++)
        {
            var cost=random.Next(100,10000); var salvage=random.Next(0,cost); var life=random.Next(1,16);
            var syd=default(Rational); var ddb=default(Rational); var balance=new Rational(cost,1);
            for(var period=1;period<=life;period++)
            {
                var sumDigits=Enumerable.Range(1,life).Sum();
                var expected=new Rational((long)(cost-salvage)*(life-period+1),sumDigits);
                var actual=Magnitude(Last($"syd({cost},{salvage},{life},{period})"));
                Assert.Equal(expected,actual); syd+=actual;
                var available=balance-new Rational(salvage,1); var expectedDdb=balance*new Rational(2,life);
                if((expectedDdb-available).Numerator.Sign>0) expectedDdb=available;
                actual=Magnitude(Last($"ddb({cost},{salvage},{life},{period})"));
                Assert.Equal(expectedDdb,actual); Assert.True(actual.Numerator.Sign>=0);
                balance-=actual; ddb+=actual; Assert.True((balance-new Rational(salvage,1)).Numerator.Sign>=0);
            }
            Assert.Equal(new Rational(cost-salvage,1),syd);
            Assert.Equal(new Rational(cost,1),ddb+balance);
        }
        Assert.Equal(new Rational(648,125),Magnitude(Last("ddb(100,0,5,5)"))); // Remains above zero; no catch-up.
    }

    [Fact]
    public void ApproximateProvenanceAndIncrementalDependenciesArePreserved()
    {
        foreach(var expression in new[]{"roi(x,x*2)","cagr(x,x*2,5)","fire(x)","sln(x,0,5)","ddb(x,0,5,2)","syd(x,0,5,2)","breakeven(x,50,30)"})
            Assert.StartsWith("≈ ",Last("x=loan 250000 at 4.99% for 30 years\n"+expression).Display);
        var session=new SheetEvaluationSession();
        var before=session.Evaluate("spend=3000\nfire spend/month at 4%\n2+2");
        var after=session.Evaluate("spend=4000\nfire spend/month at 4%\n2+2");
        Assert.Equal("900000",before[1].Display); Assert.Equal("1200000",after[1].Display);
        Assert.True(session.LastStatistics.ReusedResults>0); Assert.Equal(1,session.LastStatistics.ParsedLines);
        using var cancel=new CancellationTokenSource(); cancel.Cancel();
        Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("cagr(100,101,1199 months)",cancel.Token));
    }

    [Fact]
    public void MixedCurrencyInputsTrackSnapshotChangesAndStaticModelsRequestNoContext()
    {
        CurrencyRateSnapshot Snapshot(int dollars) => new("Planning fixture","EUR",new(2026,10,30),new(2026,10,31,0,0,0,TimeSpan.Zero),
            new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(dollars,1)});
        var context=new EvaluationContext(new(2026,10,31),CurrencyRates:new(Snapshot(2),[]));
        Assert.Equal("50%",Last("roi(100 EUR,300 USD)",context).Display);
        Assert.Equal("2000 EUR",Last("sln(10000 EUR,4000 USD,4)",context).Display);
        Assert.Contains("Planning fixture",Explain(Last("roi(100 EUR,300 USD)",context)));
        var session=new SheetEvaluationSession(); const string source="roi(100 EUR,300 USD)\n7";
        session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:context);
        var changed=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:context with{CurrencyRates=new(Snapshot(4),[])});
        Assert.Equal("-25%",changed.Results[0].Display); Assert.Equal(0,session.LastStatistics.ParsedLines);
        Assert.Equal(1,session.LastStatistics.ReusedResults);
        var staticModels=session.EvaluateWithFunctions("fire 3000 EUR/month\ncagr(100,110,5)\nddb(1000,100,5,1)",FunctionLibrary.Empty,[]);
        Assert.All(staticModels.Results,result=>Assert.Null(result.Error));
        Assert.False(staticModels.UsesCurrencyRates); Assert.False(staticModels.UsesCurrentDate); Assert.False(staticModels.UsesCurrentInstant);
    }

    [Fact]
    public void SentenceExplanationRetainsOriginalMonthlyInput()
    {
        var step=Assert.Single(Last("fire 3000/month at 4%").Explanation,item=>item.Operation=="fire");
        Assert.Equal("3000",step.Operands[0]); Assert.Contains("annualized by 12",step.Assumption);
        Assert.Equal("20.1124%",Last("cagr(1000,2500,5 years) to 4 decimals").Display.Replace("≈ ",""));
    }
}
