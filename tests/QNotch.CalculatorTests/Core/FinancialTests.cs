using System.Globalization;
using System.Numerics;
using Calc.Core;

namespace Calc.Core.Tests;

public class FinancialTests
{
    private static LineResult Last(string source, EvaluationContext? context = null)
    {
        var answer = SheetEvaluator.Evaluate(source, context: context)[^1];
        Assert.Null(answer.Error); return answer;
    }
    private static Rational Magnitude(SheetValue value) => value.Kind == SheetValueKind.Money ? value.Money.Magnitude.Scalar : value.Scalar;
    private static decimal Decimal(SheetValue value)
    {
        var r = Magnitude(value); var scaled = r.Numerator * BigInteger.Pow(10, 16) / r.Denominator;
        return (decimal)scaled / 10000000000000000m;
    }
    [Theory]
    [InlineData("loan 200k at 5% for 30 years", "1073.6432")]
    [InlineData("mortgage 300k with 20% down at 5% for 30 years", "1288.3719")]
    [InlineData("loan 2400 with 1200 down at 0% for 12 months", "100")]
    [InlineData("mortgage 300k with 100% down at 0% for 30 years", "0")]
    [InlineData("10k at 4% for 5 years", "12166.529")]
    [InlineData("5000 at 7% for 3 years compounded monthly", "6164.6279")]
    [InlineData("save 500/month at 7% for 20 years", "260463.3299")]
    [InlineData("save 100 per year at 5% for 2 years", "205")]
    [InlineData("save 100 monthly at 0% for 1.5 years", "1800")]
    [InlineData("1000 at -10% for 2 years", "810")]
    [InlineData("pmt(5%/12,360,200000)", "1073.6432")]
    [InlineData("pmt(0,12,1200)", "100")]
    [InlineData("pmt(0,12,-1200)", "-100")]
    [InlineData("pmt(0,12,1200,-600,1)", "50")]
    [InlineData("fv(10%,2,-100,-1000)", "1420")]
    [InlineData("fv(10%,2,-100,-1000,1)", "1441")]
    [InlineData("pv(10%,2,-100,0)", "173.5537")]
    [InlineData("fv(0,0,100,-1000)", "1000")]
    [InlineData("pv(0,0,100,-1000)", "1000")]
    [InlineData("npv(10%,100,200,300)", "481.5928")]
    [InlineData("npv(0,-100,200,-300)", "-200")]
    [InlineData("loan 1200 EUR at 0% for 1 year", "100 EUR")]
    [InlineData("save $100/month at 0% for 1 year", "1200 USD")]
    [InlineData("pmt(0,12,1200 USD,0)", "100 USD")]
    [InlineData("fv(0,12,-100 EUR,0)", "1200 EUR")]
    [InlineData("p=loan 1200 at 0% for 1 year\np*12", "1200")]
    [InlineData("f(p)=loan p at 0% for 1 year\nf(1200)", "100")]
    [InlineData("f(r,n,p)=pmt(r,n,p)\nf(0,12,1200)", "100")]
    [InlineData("fv(0,2,-(save 100/year at 0% for 1 year))", "200")]
    public void PublicAndBoundaryExamples(string source, string expected) => Assert.Equal(expected, Last(source).Display);

    [Fact]
    public void PaymentTimingAndSignsUseExplicitEquations()
    {
        var end = Last("pmt(10%,2,1000)").Value!.Value.Scalar;
        var begin = Last("pmt(10%,2,1000,0,1)").Value!.Value.Scalar;
        Assert.Equal(end / new Rational(11,10), begin);
        var result = Last("payment=pmt(10%,2,1000)\nfv(10%,2,-payment,1000)");
        Assert.Equal(default, result.Value!.Value.Scalar);
        Assert.Contains(Last("pmt(0,12,1200)").Explanation, step => step.Assumption?.Contains("opposite Excel PMT sign") == true);
    }
    [Fact]
    public void DisplayRoundingDoesNotChangeAuthoritativePayments()
    {
        var answer = Last("p=pmt(0,3,100)\np*3");
        Assert.Equal(new Rational(100,1), answer.Value!.Value.Scalar);
        Assert.Equal(new Rational(100,3), Last("pmt(0,3,100)").Value!.Value.Scalar);
        Assert.Equal("33.333333", Last("pmt(0,3,100) to 6 decimals").Display);
    }
    [Fact]
    public void HighPrecisionFallbackCoversOrdinaryMortgageRatesAndKeepsItsMarker()
    {
        var loan = Last("loan 250000 at 4.99% for 30 years");
        Assert.True(loan.Value!.Value.Number.IsApproximate);
        Assert.StartsWith("≈ ", loan.Display);
        // Independently evaluated with Python decimal at 60 digits, not the Core annuity implementation.
        Assert.InRange(Decimal(loan.Value.Value), 1340.5265795946524663m, 1340.5265795946524664m);
        foreach (var tail in new[] { "x*2", "x+1", "abs(x)", "x to 2 decimals", "average", "x USD", "npv(0,x)", "fv(0,1,-x)", "share(x,x)" })
            Assert.True(Last("x=loan 250000 at 4.99% for 30 years\n" + tail).Display.StartsWith("≈ "), tail);
        Assert.Contains(loan.Explanation, step => step.Assumption?.Contains("34 significant digits") == true);
        Assert.False(Last("loan 1200 at 0% for 1 year").Value!.Value.Number.IsApproximate);
    }
    [Fact]
    public void PublishedSpreadsheetCasesUseIndependentRoundedExpectations()
    {
        Assert.Equal("1037.0321", Last("pmt(8%/12,10,10000)").Display);
        Assert.Equal("1030.1643", Last("pmt(8%/12,10,10000,0,1)").Display);
        Assert.InRange(Decimal(Last("fv(6%/12,120,-200,-500)").Value!.Value), 33685.5677283086858785m, 33685.5677283086858786m);
    }
    [Fact]
    public void AmortizationRowsConservePrincipalInterestAndFinalBalance()
    {
        var answer = Last("amortize 200k at 5% for 30 years");
        var rows = Assert.Single(answer.Explanation, step => step.Schedule?.Count > 0).Schedule!;
        Assert.Equal(30, rows.Count);
        Assert.All(rows, row => Assert.Equal(12, row.Payments));
        var principal = rows.Sum(row => Decimal(row.Principal));
        var interest = rows.Sum(row => Decimal(row.Interest));
        Assert.InRange(principal, 199999.99999999m, 200000.00000001m);
        Assert.InRange(interest, 186511.568568m, 186511.568570m);
        Assert.Equal(default, Magnitude(rows[^1].Balance));
        Assert.Contains(answer.Explanation, step => step.Assumption?.Contains("display rounding is not payment settlement") == true);
    }
    [Fact]
    public void PartialYearsZeroNegativeRatesAndMaximumScheduleAreBounded()
    {
        var partial = Last("amortize 3000 at 0% for 30 months").Explanation.Single(step => step.Schedule?.Count > 0).Schedule!;
        Assert.Equal(new[] {12,12,6}, partial.Select(row => row.Payments));
        Assert.Equal(new Rational(600,1), Magnitude(partial[1].Balance));
        var negative = Last("amortize 3000 at -5% for 2 years").Explanation.Single(step => step.Schedule?.Count > 0).Schedule!;
        Assert.All(negative, row => Assert.True(Magnitude(row.Interest).Numerator.Sign < 0));
        Assert.Equal(100, Last("amortize 120000 at 0% for 100 years").Explanation.Single(step => step.Schedule?.Count > 0).Schedule!.Count);
        Assert.Equal(default, Magnitude(negative[^1].Balance));
    }
    [Fact]
    public void SeededCashFlowRecurrencesVerifyAnnuitiesAndSchedules()
    {
        var random = new Random(43019);
        for (var i = 0; i < 150; i++)
        {
            var principal = random.Next(1, 100000); var basisPoints = random.Next(-500, 2001); var n = random.Next(1, 61);
            var rateText = (basisPoints/100m).ToString(CultureInfo.InvariantCulture);
            var rate = basisPoints/10000m/12m;
            var payment = Last($"pmt({rateText}%/12,{n},{principal})").Value!.Value;
            var balance = (decimal)principal;
            for (var period = 0; period < n; period++) balance = balance*(1+rate)-Decimal(payment);
            Assert.InRange(balance, -.00000001m, .00000001m);
            var pmt = random.Next(1, 1000); var future = (decimal)principal;
            for (var period = 0; period < n; period++) future = future*(1+rate)+pmt;
            var actual = Decimal(Last($"fv({rateText}%/12,{n},-{pmt},-{principal})").Value!.Value);
            Assert.InRange(actual-future, -.00000001m, .00000001m);
        }
    }
    [Fact]
    public void LongTermsAndFallbackSchedulesAgreeWithIndependentDecimalRecurrences()
    {
        var random = new Random(77092);
        for (var trial = 0; trial < 60; trial++)
        {
            var principal = random.Next(1000, 300000); var basisPoints = random.Next(-900, 1900); var n = random.Next(180, 601);
            var rate = basisPoints / 10000m / 12m;
            var rateText = (basisPoints/100m).ToString(CultureInfo.InvariantCulture);
            var answer = Last($"amortize {principal} at {rateText}% for {n} months");
            var payment = Decimal(answer.Value!.Value); var balance = (decimal)principal;
            var rows = answer.Explanation.Single(step => step.Schedule?.Count > 0).Schedule!;
            var rowIndex = 0; decimal rowInterest = 0, rowPrincipal = 0;
            for (var period = 1; period <= n; period++)
            {
                var interest = balance*rate; rowInterest += interest; rowPrincipal += payment-interest;
                balance += interest-payment;
                if (period%12 != 0 && period != n) continue;
                var row = rows[rowIndex++];
                Assert.InRange(Decimal(row.Interest)-rowInterest, -.00000001m, .00000001m);
                Assert.InRange(Decimal(row.Principal)-rowPrincipal, -.00000001m, .00000001m);
                Assert.InRange(Decimal(row.Balance)-balance, -.00000001m, .00000001m);
                rowInterest = rowPrincipal = 0;
            }
            Assert.InRange(balance, -.00000001m, .00000001m);
        }
    }
    [Theory]
    [InlineData("x!")]
    [InlineData("(x) months")]
    [InlineData("(x) working days")]
    [InlineData("unix x")]
    [InlineData("15:00 + x h")]
    public void ApproximateAmountsCannotSilentlyBecomeExactCountsOrTimestamps(string tail)
    {
        Assert.NotNull(SheetEvaluator.Evaluate("x=(loan 250000 at 4.99% for 30 years) to 0 decimals\n"+tail)[^1].Error);
    }
    [Fact]
    public void CurrencyCashFlowsConvertOnlyWhenNeededAndKeepProvenance()
    {
        var snapshot = new CurrencyRateSnapshot("Fixture", "EUR", new(2026,10,30), new(2026,10,31,0,0,0,TimeSpan.Zero), new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(2,1)});
        var context = new EvaluationContext(new(2026,10,31), CurrencyRates:new(snapshot, []));
        var answer = Last("npv(0,10 EUR,20 USD)", context);
        Assert.Equal("20 EUR", answer.Display); Assert.Equal(snapshot.Key, answer.Value!.Value.Money.RateSnapshotKey);
        Assert.Contains(answer.Explanation, step => step.Assumption?.Contains("Fixture") == true);
        var session = new SheetEvaluationSession();
        var result = session.EvaluateWithFunctions("loan 1200 EUR at 0% for 1 year\n2+2", FunctionLibrary.Empty, []);
        Assert.False(result.UsesCurrencyRates); Assert.False(result.UsesCurrentDate); Assert.False(result.UsesCurrentInstant);
    }
    [Fact]
    public void DependenciesAndFunctionsRefreshWithoutReparsingUnchangedLines()
    {
        var session = new SheetEvaluationSession();
        var source = "principal=1200\nf(p)=pmt(0,12,p)\nf(principal)\n7";
        session.EvaluateWithFunctions(source, FunctionLibrary.Empty, []);
        var second = session.EvaluateWithFunctions(source.Replace("1200", "2400"), FunctionLibrary.Empty, []);
        Assert.Equal("200", second.Results[2].Display);
        Assert.Equal(1, session.LastStatistics.ParsedLines); Assert.True(session.LastStatistics.ReusedResults >= 1);
    }
    [Theory]
    [InlineData("loan -100 at 5% for 1 year")]
    [InlineData("mortgage 100 with 101% down at 5% for 1 year")]
    [InlineData("loan 100 with -1 down at 0% for 1 year")]
    [InlineData("loan 100 at -100% for 1 year")]
    [InlineData("100 at 5% for 1.5 years")]
    [InlineData("loan 100 at 5% for 0 years")]
    [InlineData("loan 100 at 5% for 1201 months")]
    [InlineData("loan 100 at 5% for 365 days")]
    [InlineData("save 100 at 5% for 1 year")]
    [InlineData("save 100/month at 5% for 1 year compounded annually")]
    [InlineData("pmt(5%,0,100)")]
    [InlineData("pmt(5%,1.5,100)")]
    [InlineData("pmt(5%,12,100,0,2)")]
    [InlineData("pmt(5%,12,100,0,0,1)")]
    [InlineData("pmt(5%,12)")]
    [InlineData("pmt(sqrt(2),12,100)")]
    [InlineData("pmt(0,12,100 kg)")]
    [InlineData("pv(-100%,12,100)")]
    [InlineData("npv(10%)")]
    [InlineData("npv(-100%,100)")]
    [InlineData("npv(0,100 USD,100)")]
    [InlineData("loan 100 USD with 10 down at 0% for 1 year")]
    [InlineData("loan 100 USD/h at 5% for 1 year")]
    [InlineData("f(x)=pmt(x)\nf(1)")]
    public void InvalidInputsNeverPublishPlausibleResults(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);
    [Fact]
    public void CancellationAndSharedBudgetsRemainActive()
    {
        using var cancel = new CancellationTokenSource(); cancel.Cancel();
        Assert.Throws<OperationCanceledException>(() => SheetEvaluator.Evaluate("amortize 10000 at 5% for 30 years", cancel.Token));
        var source = string.Join('\n', Enumerable.Repeat("amortize 1000 at 5% for 100 years", 200));
        Assert.Throws<SheetComputationLimitException>(() => SheetEvaluator.Evaluate(source));
    }
}
