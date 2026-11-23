using NodaTime;

namespace Calc.Core;

internal sealed partial class HelperArithmetic
{
    internal const string FuelUnits = "mpg is the US gallon (3.785411784 L), mpg uk the imperial gallon (4.54609 L); l/100km and mpg are reciprocal, so 235.2146 / (l/100km) = US mpg";
    internal const string FuelBasis = "Fuel = distance at consumption: volume per distance (l/100km) multiplies, distance per volume (mpg, km/l) divides; " + FuelUnits + "; two-decimal display, exact value kept";
    internal const string OffsetBasis = "Offset of the second zone minus offset of the first, in UTC offsets: positive means the second place's clock is ahead";
    internal Outcome FuelTrip(SheetValue[] inputs)
    {
        var metres = Quantity(inputs[0], Length, "Distance", "length");
        var number = NumberOf(inputs[1], "Consumption");
        var form = number.Unit?.FuelForm() ?? 0;
        if (form == 0 || !number.IsRational || number.Exact.Rational.Numerator.Sign <= 0) throw new ArithmeticException("Consumption must be a positive fuel unit such as 6.5 l/100km or 36 mpg");
        var cubicMetres = form == 1 ? metres * number.Exact.Rational : metres / number.Exact.Rational;
        var volume = new NumericValue(new ExactNumber(cubicMetres), number.Unit!.FuelVolume()) { DisplayDecimalPlaces = 2, IsApproximate = Approximate(inputs) };
        if (inputs.Length == 2) return new(Result(volume), "fuel for distance", FuelBasis);
        var cost = new MoneyArithmetic(math, context, reads).Binary("*", Result(volume), inputs[2]);
        return new(cost, "fuel cost", FuelBasis + "; cost = volume * supplied price per volume");
    }
    internal Outcome TimeDifference(SheetValue[] inputs, string first, string second)
    {
        Instant instant;
        if (inputs.Length == 1)
        {
            var date = inputs[0].Kind == SheetValueKind.Date ? inputs[0].Date : throw new ArithmeticException("Expected a date");
            instant = Instant.FromUtc(date.Year, date.Month, date.Day, 12, 0);
        }
        else { reads.Dependencies |= ContextDependency.Instant; instant = context.RequireNow(); }
        var a = ZoneCatalog.Resolve(first, context, reads, out var version).GetUtcOffset(instant); var b = ZoneCatalog.Resolve(second, context, reads, out _).GetUtcOffset(instant);
        var value = TimeArithmetic.Duration((long)(b.Seconds - a.Seconds) * TimeSpan.TicksPerSecond);
        return new(Result(value), "time difference", OffsetBasis + "; " + first + " " + a + ", " + second + " " + b + " at " + instant + (inputs.Length == 1 ? " (12:00 UTC on the given date)" : " (evaluation instant snapshot)") + "; rules " + version);
    }
}
