namespace Calc.Core;

internal sealed record StatisticsResult(SheetValue Value, string Assumption);

internal sealed class StatisticsArithmetic(ExactArithmetic math, ExecutionBudget budget, CancellationToken token, MoneyArithmetic money)
{
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "sum" or "mean" or "average" or "avg" or "median" or "min" or "max" or "count" or "stdev" or "stddev" or "stdevp" or "variance" or "variancep" or "percentile";
    internal static void ValidateArity(string name, int count)
    {
        if (name.Equals("percentile", StringComparison.OrdinalIgnoreCase))
        { if (count != 2) throw new FormatException("percentile expects 2 arguments"); }
        else if (count is < 1 or > 16) throw new FormatException($"{name} expects 1–16 arguments or a list");
    }
    internal static SheetValue[] Flatten(IEnumerable<SheetValue> arguments, ExecutionBudget budget, CancellationToken token)
    {
        var values = new List<SheetValue>();
        foreach (var argument in arguments)
        {
            if (argument.Kind == SheetValueKind.List)
                foreach (var item in argument.List.Values) Add(item);
            else Add(argument);
        }
        return values.ToArray();
        void Add(SheetValue value)
        {
            budget.Step(token);
            if (values.Count == SheetList.MaxItems) throw new ArithmeticException("Combined list exceeds 1024 values");
            if (value.Kind is not SheetValueKind.Number and not SheetValueKind.Money) throw new ArithmeticException("Statistics and cash flows require numeric or monetary values");
            values.Add(value);
        }
    }
    internal StatisticsResult Function(string name, SheetValue[] args)
    {
        ValidateArity(name, args.Length); var key = name.ToLowerInvariant();
        var values = Flatten(key == "percentile" ? args.Take(1) : args, budget, token);
        if (key == "count") return new(new(new Rational(values.Length, 1)), values.Length + " list/scalar entries; exact count; no text, dates or invalid values silently skipped");
        if (values.Length == 0)
        {
            if (key == "sum") return new(new(new Rational(0, 1)), "Empty numeric sum is zero");
            throw new ArithmeticException("Statistics require a nonempty sample");
        }
        MoneyValue? currency = values[0].Kind == SheetValueKind.Money ? values[0].Money : null;
        var numbers = new NumericValue[values.Length];
        for (var i = 0; i < values.Length; i++)
        {
            budget.Step(token);
            if ((values[i].Kind == SheetValueKind.Money) != (currency is not null)) throw new ArithmeticException("Do not mix bare and monetary statistical samples");
            if (currency is null) numbers[i] = values[i].Number;
            else
            {
                var converted = money.Convert(values[i].Money, currency.Currency);
                if (currency.RateStamp is not null && converted.RateStamp is not null && currency.RateSnapshotKey != converted.RateSnapshotKey)
                    throw new ArithmeticException("Statistical sample uses different currency snapshots");
                currency = new(currency.Magnitude, currency.Currency, currency.RateStamp ?? converted.RateStamp);
                numbers[i] = converted.Magnitude;
            }
        }
        var first = numbers[0]; var kind = first.QuantityKind;
        foreach (var number in numbers)
        {
            if (number.Unit?.Dimension != first.Unit?.Dimension || number.IsPercentage != first.IsPercentage || number.Unit?.IsTemperaturePoint != first.Unit?.IsTemperaturePoint)
                throw new ArithmeticException("Statistical sample requires compatible dimensions and value types");
            if (kind.Length > 0 && number.QuantityKind.Length > 0 && kind != number.QuantityKind) throw new ArithmeticException("Statistical sample contains incompatible quantity kinds");
            if (kind.Length == 0) kind = number.QuantityKind;
        }
        var approximate = numbers.Any(number => number.IsApproximate);
        var quantities = new QuantityArithmetic(math);
        SheetValue Wrap(NumericValue number) => currency is null ? new(number) : new(new MoneyValue(number, currency.Currency, currency.RateStamp));
        StatisticsResult Result(NumericValue number, string convention)
            => new(Wrap(number with { IsApproximate = number.IsApproximate || approximate }), values.Length + " values; " + convention +
                "; exact represented magnitudes, display rounding retained separately" + (money.Provenance is { } source ? "; " + source : ""));
        NumericValue Location(ExactNumber exact) => first with { Exact = exact, QuantityKind = kind, IsApproximate = approximate, DisplayDecimalPlaces = 4, UseCompoundDuration = false, UseDaysInDuration = false };
        if (key == "sum") return Result(quantities.Aggregate(numbers, false, token), "Numeric sum; absolute temperatures cannot be summed");
        if (key is "mean" or "average" or "avg")
            return Result(quantities.Aggregate(numbers, true, token) with { DisplayDecimalPlaces = 4, UseCompoundDuration = false, UseDaysInDuration = false }, "Arithmetic mean; sum / count; first sample unit/currency retained");
        if (key is "variance" or "variancep" or "stdev" or "stddev" or "stdevp")
        {
            var population = key is "variancep" or "stdevp"; var deviation = key is "stdev" or "stddev" or "stdevp";
            if (!population && numbers.Length < 2) throw new ArithmeticException("Sample variance/deviation requires at least two values");
            if (!deviation && currency is not null) throw new ArithmeticException("Monetary variance has squared currency units; use stdev or numeric magnitudes");
            var sum = default(ExactNumber);
            foreach (var number in numbers) { budget.Step(token); sum = math.Add(sum, number.Exact); }
            var mean = math.Scale(sum, new(1, numbers.Length)); var squares = default(ExactNumber);
            foreach (var number in numbers)
            {
                budget.Step(token); var distance = math.Subtract(number.Exact, mean);
                squares = math.Add(squares, math.Multiply(distance, distance));
            }
            var divisor = numbers.Length - (population ? 0 : 1);
            var variance = math.Scale(squares, new(1, divisor));
            var exact = deviation ? math.SquareRoot(variance) : variance;
            var unit = first.Unit?.Delta();
            if (!deviation) unit = unit?.Power(new(2, 1));
            var output = (unit is null ? new NumericValue(exact, deviation && first.IsPercentage) : new NumericValue(exact, unit)) with
                { IsApproximate = approximate, DisplayDecimalPlaces = 4 };
            return Result(output, (population ? "Population" : "Sample") + (deviation ? " standard deviation; square root of centered sum of squares / " : " variance; centered sum of squares / ") + divisor +
                (first.Unit?.IsTemperaturePoint == true ? "; temperature dispersion is a difference, not an absolute temperature" : "") +
                (first.IsPercentage && !deviation ? "; percentage variance expressed in squared ratios" : ""));
        }
        if (key is "min" or "max")
        {
            var selected = first.Exact;
            foreach (var number in numbers)
            {
                budget.Step(token); var comparison = math.Sign(math.Subtract(number.Exact, selected));
                if (key == "min" ? comparison < 0 : comparison > 0) selected = number.Exact;
            }
            return Result(first with { Exact = selected, QuantityKind = kind }, "Exact ordering of represented magnitudes; first sample unit/currency retained");
        }
        var ordered = Sort(numbers);
        Rational fraction;
        if (key == "median") fraction = new(1, 2);
        else
        {
            var percentile = args[1].Number;
            if (percentile.Unit is not null || !percentile.IsRational) throw new ArithmeticException("Percentile requires a dimensionless rational from 0 to 100 (or 0% to 100%)");
            fraction = percentile.IsPercentage ? percentile.Scalar : percentile.Scalar / new Rational(100, 1);
            if (fraction.Numerator.Sign < 0 || fraction.Numerator > fraction.Denominator) throw new ArithmeticException("Percentile must be from 0 to 100 (or 0% to 100%)");
            approximate |= percentile.IsApproximate;
        }
        var rank = fraction * new Rational(ordered.Length-1, 1);
        var index = (int)(rank.Numerator/rank.Denominator); var remainder = rank - new Rational(index, 1);
        var location = ordered[index].Exact;
        if (!remainder.Numerator.IsZero)
            location = math.Add(location, math.Scale(math.Subtract(ordered[index+1].Exact, location), remainder));
        return Result(Location(location), key == "median" ? "Median; sorted middle value or arithmetic mean of the two middle values" :
            "Inclusive linear percentile; zero-based rank (n-1)*p; bare p is percentage points, % input is a ratio; no nearest-rank substitution");
    }
    private NumericValue[] Sort(NumericValue[] numbers)
    {
        // Stable bounded merge sort. Comparer failures propagate directly, rather than being wrapped by Array.Sort.
        var sorted = numbers.ToArray(); var temporary = new NumericValue[numbers.Length];
        for (var width = 1; width < sorted.Length; width *= 2)
        {
            for (var start = 0; start < sorted.Length; start += width*2)
            {
                var middle = Math.Min(start+width, sorted.Length); var end = Math.Min(start+width*2, sorted.Length);
                var left = start; var right = middle;
                for (var target = start; target < end; target++)
                {
                    budget.Step(token);
                    if (right == end || left < middle && math.Sign(math.Subtract(sorted[left].Exact, sorted[right].Exact)) <= 0) temporary[target] = sorted[left++];
                    else temporary[target] = sorted[right++];
                }
            }
            (sorted, temporary) = (temporary, sorted);
        }
        return sorted;
    }
}
