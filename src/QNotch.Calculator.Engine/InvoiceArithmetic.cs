namespace Calc.Core;

internal sealed partial class FinancialArithmetic
{
    internal FinancialResult LateFee(SheetValue principal,SheetValue dailyRate,SheetValue duration)
    {
        SetTemplate([principal]); var amount=Cash(principal); Nonnegative(amount,"Late-fee principal");
        var rate=Plain(dailyRate,true); Nonnegative(rate,"Daily late-fee rate");
        var time=duration.Number;
        if(time.Unit?.Dimension!=TimeArithmetic.TimeDimension || !time.IsRational || time.IsPercentage || time.IsApproximate)
            throw new ArithmeticException("Late-fee duration requires an exact elapsed-time quantity");
        var days=Divide(time.Exact.Rational,new(86400,1)); Nonnegative(days,"Late-fee duration");
        if(days.Numerator>3660000*days.Denominator) throw new ArithmeticException("Late-fee duration exceeds 3,660,000 days");
        return new(Output(Multiply(Multiply(amount,rate),days)),PlanningAssumption("Simple late fee = principal * explicit daily rate * elapsed days; fractional days prorated; day = 24 elapsed hours; no compounding, legal rate, grace period or statutory entitlement inferred"));
    }
    internal static SheetValue InvoiceDue(SheetValue issue,SheetValue term)
    {
        var number=term.Number;
        if(!number.IsRational || number.Unit is not null || number.IsPercentage || number.IsApproximate || number.Scalar.Denominator!=1 || number.Scalar.Numerator<0 || number.Scalar.Numerator>3660000)
            throw new ArithmeticException("Net terms require an exact whole calendar-day count from 0 to 3,660,000");
        try { return new(issue.Date.AddDays((int)number.Scalar.Numerator)); }
        catch(ArgumentOutOfRangeException) { throw new ArithmeticException("Invoice due date exceeds the Gregorian date range"); }
    }
}
