namespace Calc.Core;

public enum EarningsPeriod { Hour, Day, Month, Year }

/// <summary>Amount per earnings period; calendar rates are not fixed elapsed-time quantities.</summary>
public sealed record EarningsValue
{
    public SheetValue Amount { get; }
    public EarningsPeriod Period { get; }
    public EarningsValue(SheetValue amount,EarningsPeriod period)
    {
        var number=amount.Kind==SheetValueKind.Money?amount.Money.Magnitude:amount.Number;
        if(number.Unit is not null || number.IsPercentage || !Enum.IsDefined(period)) throw new ArithmeticException("Earnings require an amount without physical units or percentages");
        Amount=amount; Period=period;
    }
    public string Display
    {
        get
        {
            var text=Amount.Display+"/"+(Period==EarningsPeriod.Day?"workday":Period.ToString().ToLowerInvariant());
            if(text.Length>2048) throw new ArithmeticException("Earnings output limit exceeded");
            return text;
        }
    }
}
