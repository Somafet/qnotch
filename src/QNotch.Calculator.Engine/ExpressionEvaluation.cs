using System.Numerics;

namespace Calc.Core;

internal static class ExpressionEvaluation
{

    internal static IEnumerable<Expression> Children(Expression expression) => expression switch
    {
        HelperExpression h => h.Operands, EquationExpression e => e.Inputs, IntegralExpression i => i.Inputs, DerivativeExpression d => d.Inputs, PlotExpression p => p.Inputs, ChartExpression { Data: { } data } => [data],
        UsageConvertExpression c=>[c.Operand], UsageCountExpression c=>[c.Operand], UsagePriceExpression p=>[p.Operand], RateForExpression r=>[r.Rate,r.Duration],
        NetworkMembershipExpression n => [n.Address, n.Subnet], IntegerConvertExpression i => [i.Operand], ChemistryExpression c => c.Amount is null ? [] : [c.Amount], GradesExpression g => g.Scores.Concat(g.Weights), EngineeringExpression e => [e.Operand],
        SalaryExpression salary => [salary.Amount],
        EarningsAttachExpression e => [e.Operand], EarningsConvertExpression e => [e.Operand], InvoiceDueExpression i => [i.Date,i.Days], LateFeeExpression l => [l.Principal,l.Rate,l.Duration],
        PlanningSentenceExpression p => p.Arguments,
        FinancialPlanExpression f => f.DownPayment is null ? [f.Amount, f.Rate, f.Term] : [f.Amount, f.Rate, f.Term, f.DownPayment],
        UnaryExpression u => [u.Operand], BinaryExpression b => [b.Left, b.Right], CallExpression c => c.Arguments, DateShiftExpression d => [d.Date, d.Offset], TimeRangeExpression t => [t.Start, t.End],
        WorkdayPeriodExpression w => [w.Count], WorkdayCountExpression w => [w.From, w.To], ListExpression list => list.Items,
        CurrencyAttachExpression c => [c.Operand], CurrencyConvertExpression c => c.Date is null ? [c.Operand] : [c.Date,c.Operand],
        TimestampJoinExpression t => [t.Date, t.Time], ZoneExpression z => [z.Operand], UnixExpression u => [u.Operand], UnitOrZoneExpression u => [u.Operand], CountdownExpression c => [c.Deadline], CountdownZoneExpression c => [c.Deadline],
        RoundingExpression r => [r.Operand, r.Precision], ScaleExpression s => [s.Operand], UnitExpressionNode u => [u.Operand], CalendarPeriodExpression c => [c.Count], DateIntervalExpression d => [d.From, d.To], _ => []
    };
    internal static AggregateExpression? SheetAggregate(Expression? expression)
    {
        while (expression is UsageConvertExpression or RoundingExpression or UnitExpressionNode or CurrencyConvertExpression or EarningsConvertExpression or EngineeringExpression or IntegerConvertExpression)
            expression = expression switch { UsageConvertExpression usage => usage.Operand, IntegerConvertExpression integer => integer.Operand, RoundingExpression rounding => rounding.Operand, UnitExpressionNode unit => unit.Operand, CurrencyConvertExpression currency => currency.Operand, EarningsConvertExpression earnings => earnings.Operand, EngineeringExpression engineering => engineering.Operand, _ => expression };
        return expression as AggregateExpression;
    }
    /// <summary>Kinds that block sum/average skip, never crash: lists and matrices are data lines; add a non-scalar kind here.</summary>
    internal static bool ExcludedFromAggregate(SheetValue value) => MatrixArithmetic.IsCollection(value) || value.Kind is SheetValueKind.Equation or SheetValueKind.Complex or SheetValueKind.Prime or SheetValueKind.Plot or SheetValueKind.Chart or SheetValueKind.Table || value.Kind == SheetValueKind.Practical && value.Practical.Original is null;
    /// <summary>Lines that present data rather than contribute a value to their block, so an error on one never reaches sum or average.</summary>
    internal static bool IsPresentation(Expression? expression) => expression is PlotExpression or ChartExpression or TableExpression;
    internal static IEnumerable<Expression> Walk(Expression expression)
    {
        var stack = new Stack<Expression>(); stack.Push(expression);
        while (stack.TryPop(out var node)) { yield return node; foreach (var child in Children(node)) stack.Push(child); }
    }
    internal static (SheetValue Value, CalculationStep[] Steps) Evaluate(Expression expression,
        Func<string, SheetValue> resolve, IReadOnlyList<SheetValue> aggregate, CancellationToken cancellationToken,
        Func<string, SheetValue[], EvaluationContext, (SheetValue Value, CalculationStep[] Steps)>? userFunction = null, ExecutionBudget? budget = null, Func<string, string?>? describeFunction = null, EvaluationContext? context = null, ContextReads? contextReads = null)
    {
        var stack = new Stack<(Expression Node, bool Ready)>(); stack.Push((expression, false));
        var values = new Stack<SheetValue>(); var steps = new List<CalculationStep>(); budget ??= new();
        using var scope = budget.Scope();
        context ??= new(); contextReads ??= new();
        var math = new ExactArithmetic(budget, cancellationToken); var quantities = new QuantityArithmetic(math); var dates = new DateArithmetic(context); var timestamps = new TimestampArithmetic(context, contextReads); var countdowns = new CountdownArithmetic(context, contextReads);
        var textMath = new TextArithmetic(budget, cancellationToken);
        var developerMath = new DeveloperArithmetic(budget, cancellationToken);
        var networkMath = new NetworkArithmetic(budget, cancellationToken);
        var integerMath = new IntegerArithmetic(budget, cancellationToken);
        var practicalMath = new PracticalArithmetic(math, budget, cancellationToken);
        var chemistryMath = new ChemistryArithmetic(budget, cancellationToken);
        var electricalMath = new ElectricalArithmetic(math, budget, cancellationToken);
        var matrixMath = new MatrixArithmetic(math, budget, cancellationToken);
        var workdayMath = new WorkdayArithmetic(budget, cancellationToken);
        var moneyMath = new MoneyArithmetic(math,context,contextReads);
        var rateMath = new RateArithmetic(math,budget,cancellationToken,moneyMath);
        var earningsMath = new EarningsArithmetic(math,moneyMath,workdayMath,context,contextReads,cancellationToken);
        var formulaMath = new FormulaArithmetic(math, budget, cancellationToken);
        var complexMath = new ComplexArithmetic(math, quantities, budget, cancellationToken);
        var primeMath = new PrimeArithmetic(math, budget, cancellationToken);
        var helperMath = new HelperArithmetic(math, budget, context, contextReads, cancellationToken);
        WorkdayCalendar ReadWorkdayCalendar()
        { contextReads.Dependencies |= ContextDependency.WorkdayCalendar; return new(context.WorkdayRegion, context.CustomHolidays); }
        static string Preview(string text) => text.Length <= 96 ? text : text[..96] + "…";
        void Record(string op, SheetValue[] args, SheetValue result, string? assumption = null)
        {
            if (assumption?.StartsWith(RateArithmetic.Convention,StringComparison.Ordinal) == true)
                assumption += "\n" + string.Join("\n",args.Take(8).Select((v,i)=>"Input " + (i+1) + ": " + RateArithmetic.Evidence(v))) + "\nResult: " + RateArithmetic.Evidence(result);
            if (result.Kind == SheetValueKind.Resistor) assumption = (assumption is null ? "" : assumption + "; ") + ElectricalArithmetic.MarkingAssumption(result.Resistor);
            static bool Approximate(SheetValue value) => value.Kind == SheetValueKind.Plot || value.Kind == SheetValueKind.Chart && value.Chart.IsApproximate || value.Kind == SheetValueKind.Practical && value.Practical.IsApproximate || value.Kind == SheetValueKind.Complex && value.Complex.IsApproximate || value.Kind == SheetValueKind.Equation && value.Equation.IsApproximate || value.Kind == SheetValueKind.Engineering && value.Engineering.Original.IsApproximate || value.Kind == SheetValueKind.Number && value.Number.IsApproximate || value.Kind == SheetValueKind.Money && value.Money.Magnitude.IsApproximate || value.Kind == SheetValueKind.List && value.List.IsApproximate || value.Kind == SheetValueKind.Matrix && value.Matrix.IsApproximate || value.Kind==SheetValueKind.Earnings && Approximate(value.Earnings.Amount) || value.Kind==SheetValueKind.UsageCount && value.UsageCount.Quantity.IsApproximate || value.Kind==SheetValueKind.UsagePrice && value.UsagePrice.Amount.Magnitude.IsApproximate;
            if (Approximate(result) || args.Any(Approximate)) assumption = "Approximate input/result; " + assumption;
            if (steps.Count < 63) steps.Add(new(op, Array.AsReadOnly(args.Select(v => Preview(v.Display)).ToArray()), Preview(result.Display), assumption));
        }
        SheetValue Nominal(SheetValue value)
        {
            if (value.Kind == SheetValueKind.UptimeBudget) { var duration=rateMath.Nominal(value.UptimeBudget);Record("uptime budget duration",[value],duration,value.UptimeBudget.Details);return duration; }
            if (value.Kind == SheetValueKind.Integer) { budget.Step(cancellationToken); var original = new SheetValue(new Rational(value.Integer.Value, 1)); Record("integer magnitude", [value], original, "Exact interpreted word value used; word/base profile leaves integer arithmetic"); return original; }
            if (value.Kind == SheetValueKind.Engineering) { budget.Step(cancellationToken); var original = new SheetValue(value.Engineering.Original); Record("engineering source magnitude", [value], original, "Exact represented value used; engineering presentation rounding is not a change to the stored magnitude"); return original; }
            if (value.Kind == SheetValueKind.Practical && value.Practical.Original is { } presented) { budget.Step(cancellationToken); var original = new SheetValue(presented); Record("practical magnitude", [value], original, "Exact value used; m:ss, h:mm:ss and pace presentation round to whole seconds for display only"); return original; }
            if (value.Kind != SheetValueKind.Resistor) return value;
            budget.Step(cancellationToken); var nominal = new SheetValue(value.Resistor.Nominal);
            Record("nominal resistance", [value], nominal, ElectricalArithmetic.NominalAssumption(value.Resistor));
            return nominal;
        }
        // Units and money never attach to a complex value.
        SheetValue Real(SheetValue value) { value = Nominal(value); return value.Kind == SheetValueKind.Complex ? throw new ArithmeticException(ComplexArithmetic.Refusal) : value; }
        // Keep the large primitive-operation frame out of nested user-function/context evaluations.
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        SheetValue EvaluateNode(Expression currentNode)
        {
            SheetValue result;
            switch (currentNode)
            {
                case EquationExpression equation:
                {
                    var inputs = new SheetValue[equation.Inputs.Length]; for (var i = inputs.Length - 1; i >= 0; i--) inputs[i] = Nominal(values.Pop());
                    var solved = formulaMath.Solve(equation, inputs); result = solved.Value; Record("solve for " + equation.Variable, inputs.Take(8).ToArray(), result, solved.Assumption); break;
                }
                case IntegralExpression integral:
                {
                    var inputs = new SheetValue[integral.Inputs.Length]; for (var i = inputs.Length - 1; i >= 0; i--) inputs[i] = Nominal(values.Pop());
                    var integrated = formulaMath.Integrate(integral, inputs); result = integrated.Value; Record("integral over " + integral.Variable, inputs.Take(8).ToArray(), result, integrated.Assumption); break;
                }
                case DerivativeExpression derivative:
                {
                    var inputs = new SheetValue[derivative.Inputs.Length]; for (var i = inputs.Length - 1; i >= 0; i--) inputs[i] = Nominal(values.Pop());
                    var differentiated = formulaMath.Differentiate(derivative, inputs); result = differentiated.Value; Record("derivative in " + derivative.Variable, inputs.Take(8).ToArray(), result, differentiated.Assumption); break;
                }
                case HelperExpression helper:
                {
                    var inputs = new SheetValue[helper.Operands.Length]; for (var i = inputs.Length - 1; i >= 0; i--) inputs[i] = Nominal(values.Pop());
                    var computed = helperMath.Evaluate(helper, inputs); result = computed.Value; Record(computed.Operation, inputs.Take(8).ToArray(), result, computed.Assumption); break;
                }
                case ConstantExpression constant:
                {
                    if (!ConstantCatalog.TryFind(constant.Name, out var entry)) throw new FormatException("Unknown constant: " + constant.Name);
                    budget.Step(cancellationToken); result = ConstantCatalog.Resolve(entry, constant.Magnitude);
                    Record(constant.Name, [], result, entry.Assumption + (constant.Magnitude ? ConstantCatalog.FormulaNote : "")); break;
                }
                case ImaginaryExpression imaginary: result = ComplexArithmetic.Literal(imaginary.Coefficient); break;
                case PlotExpression plot:
                {
                    var inputs = new SheetValue[plot.Inputs.Length]; for (var i = inputs.Length - 1; i >= 0; i--) inputs[i] = Nominal(values.Pop());
                    var sampled = PlotArithmetic.Plot(plot, inputs, math, budget, cancellationToken); result = sampled.Value; Record("plot", inputs.Take(8).ToArray(), result, sampled.Assumption); break;
                }
                case ChartExpression chart:
                {
                    SheetValue? data = chart.Data is null ? null : Nominal(values.Pop());
                    var built = new ChartArithmetic(math, budget, cancellationToken, moneyMath).Build(chart.Kind, data, aggregate.Select(Nominal).ToArray(), context.AggregateLabels);
                    result = built.Value; Record("chart", data is null ? [] : [data.Value], result, built.Assumption); break;
                }
                case TableExpression table: result = new(table.Value); Record("table", [], result, table.Value.Summary.Replace("\n", "; ")); break;
                case UsageConvertExpression conversion:
                    var convertedUsage=values.Pop();result=rateMath.ConvertCount(convertedUsage.UsageCount,conversion.Kind,conversion.Unit);Record("usage rate conversion",[convertedUsage],result,RateArithmetic.Convention);break;
                case UsageCountExpression usage:
                    var usageInput=Nominal(values.Pop());result=rateMath.Count(usageInput,usage.Kind);Record("usage count",[usageInput],result,RateArithmetic.Convention);break;
                case UsagePriceExpression price:
                    var priceInput=values.Pop();result=rateMath.Price(priceInput,price.PerCount,price.Kind);Record("usage price",[priceInput],result,RateArithmetic.Convention);break;
                case RateForExpression:
                    var rateDuration=Nominal(values.Pop());var elapsedRate=values.Pop();result=rateMath.For(elapsedRate,rateDuration);Record("elapsed rate total",[elapsedRate,rateDuration],result,RateArithmetic.Convention+"; fixed elapsed days are 24 hours; no tiers, taxes or calendar billing inferred");break;
                case UuidExpression uuid:
                    contextReads.Dependencies |= ContextDependency.Uuid;
                    result = new(new TextValue(context.Uuids?.Resolve(context.UuidLine, context.UuidPath, uuid.Site, contextReads) ?? throw new ArithmeticException("UUID requires a document generation context")));
                    Record("uuid", [], result, "Stable version-4 UUID; editing this expression generates a new value; other expressions, reevaluation and saved-sheet restart retain it; not a security token"); break;
                case DiceExpression dice:
                {
                    contextReads.Dependencies |= ContextDependency.Dice;
                    var roll = context.UuidPath.Length == 0 ? context.Uuids?.Dice(context.UuidLine) : null;
                    if (roll is null || roll.Formula != dice.Formula.Notation || !dice.Formula.Fits(roll.Faces))
                    { var preview = DiceSyntax.Preview(dice.Formula); throw new DiceUnrolledException(preview.Preview, preview.Steps); }
                    budget.Step(cancellationToken);
                    var rolled = DiceSyntax.Total(dice.Formula, roll.Faces);
                    result = new(new Rational(rolled.Total, 1)); foreach (var step in rolled.Steps) if (steps.Count < 63) steps.Add(step); break;
                }
                case ColourLiteralExpression colour: result = developerMath.ColourLiteral(colour.Text); break;
                case TextLiteralExpression textLiteral: result = textMath.Literal(textLiteral.Value); break;
                case IpLiteralExpression ip: result = networkMath.Literal(ip.Text); break;
                case PrefixMaskExpression mask: result = networkMath.PrefixMask(mask.Prefix, mask.Family); Record("network mask", [], result, NetworkArithmetic.Convention); break;
                case NetworkMembershipExpression:
                { var networkTarget = values.Pop(); var networkCandidate = values.Pop(); result = networkMath.Contains(networkCandidate, networkTarget); Record("network membership", [networkCandidate, networkTarget], result, NetworkArithmetic.Convention); break; }
                case IntegerLiteralExpression integer: result = integerMath.Literal(integer.Text); break;
                case IntegerConvertExpression integer:
                {
                    var integerInput = values.Pop();
                    var colourConversion = integerInput.Kind == SheetValueKind.Colour && integer.Radix == 16 && integer.Width is null;
                    result = colourConversion ? developerMath.Function("colourhex", [integerInput]) : integerMath.Convert(integerInput, integer.Radix, integer.Width, integer.Signed);
                    Record(colourConversion ? "colour hex presentation" : "integer conversion", [integerInput], result, colourConversion ? DeveloperArithmetic.Convention : IntegerArithmetic.Convention); break;
                }
                case ChemistryExpression chemistry:
                {
                    var chemicalInput = chemistry.Amount is null ? (SheetValue?)null : Nominal(values.Pop());
                    var evaluated = chemistryMath.Evaluate(chemistry, chemicalInput); result = evaluated.Value;
                    Record(chemistry.Amount is null ? "molar mass" : "chemical mass/amount", chemicalInput is null ? [] : [chemicalInput.Value], result, ChemistryArithmetic.Assumption + "; " + evaluated.Evidence.Formula + "; " + evaluated.Evidence.RuleId);
                    if (steps.Count < 63) steps[^1] = steps[^1] with { Chemistry = evaluated.Evidence }; break;
                }
                case EngineeringExpression:
                { var engineeringInput = Nominal(values.Pop()); result = practicalMath.Engineering([engineeringInput]); Record("engineering notation", [engineeringInput], result, PracticalArithmetic.EngineeringAssumption); break; }
                case GradesExpression grades:
                {
                    var weights = new SheetValue[grades.Weights.Length]; var scores = new SheetValue[grades.Scores.Length];
                    for (var i = weights.Length - 1; i >= 0; i--) weights[i] = Nominal(values.Pop());
                    for (var i = scores.Length - 1; i >= 0; i--) scores[i] = Nominal(values.Pop());
                    result = practicalMath.Grades(scores, weights); Record("weighted grades", scores.Take(8).ToArray(), result, "Weighted mean sum(score*weight) / sum(weight); nonnegative weights, no grading range or pass threshold inferred; exact represented magnitudes, four-decimal display"); break;
                }
                case SalaryExpression salary:
                    var salaryInput=Nominal(values.Pop()); var salaryResult=new PayrollArithmetic(budget,cancellationToken,moneyMath,context,contextReads).Evaluate(salary,salaryInput);
                    result=salaryResult.Value; Record(salary.EmployerCost?"salary employer cost":salary.Inverse?"salary net to gross":"salary gross to net",[salaryInput],result,salaryResult.Assumption);
                    if(steps.Count<63) steps[^1]=steps[^1] with{Payroll=salaryResult.Evidence}; break;
                case EarningsAttachExpression earnings:
                    var earningsAmount=Real(values.Pop()); result=new(new EarningsValue(earningsAmount,earnings.Period));
                    Record("earnings period",[earningsAmount],result,"Calendar earnings rate; month/year is not a fixed elapsed duration"); break;
                case EarningsConvertExpression earnings:
                    var earningsSource=Nominal(values.Pop()); result=earningsMath.Convert(earningsSource,earnings.Period);
                    Record("convert earnings",[earningsSource],result,earningsMath.Assumption); break;
                case InvoiceDueExpression:
                    var invoiceDays=Nominal(values.Pop()); var invoiceDate=Nominal(values.Pop()); result=FinancialArithmetic.InvoiceDue(invoiceDate,invoiceDays);
                    Record("invoice due date",[invoiceDate,invoiceDays],result,"Net terms; whole Gregorian calendar days after issue date; zero retains issue date; no weekend/holiday adjustment or legal payment rule inferred"); break;
                case LateFeeExpression:
                    var feeDuration=Nominal(values.Pop()); var feeRate=Nominal(values.Pop()); var feePrincipal=Nominal(values.Pop());
                    var fee=new FinancialArithmetic(budget,cancellationToken,moneyMath).LateFee(feePrincipal,feeRate,feeDuration);
                    result=fee.Value; Record("late fee",[feePrincipal,feeRate,feeDuration],result,fee.Assumption); break;
                case PlanningSentenceExpression planning:
                {
                    var inputs=new SheetValue[planning.Arguments.Length];
                    for(var i=inputs.Length-1;i>=0;i--) inputs[i]=Nominal(values.Pop());
                    var evaluated=new FinancialArithmetic(budget,cancellationToken,moneyMath).PlanningSentence(planning,inputs);
                    result=evaluated.Value; Record(planning.Name,inputs,result,evaluated.Assumption); break;
                }
                case FinancialPlanExpression financial:
                {
                    var inputs = new SheetValue[financial.DownPayment is null ? 3 : 4];
                    for (var i = inputs.Length-1; i >= 0; i--) inputs[i] = Nominal(values.Pop());
                    if(financial.Kind=="grow"&&!inputs[1].IsPercentage)
                    {
                        if(financial.CompoundingSpecified)throw new ArithmeticException("Compounding applies to percentage growth, not a flat unit price");
                        result=rateMath.For(rateMath.At(inputs[0],inputs[1]),inputs[2]);Record("priced rate total",inputs,result,RateArithmetic.Convention+"; fixed elapsed days are 24 hours; no tiers, taxes or calendar billing inferred");break;
                    }
                    var evaluated = new FinancialArithmetic(budget, cancellationToken, moneyMath).Plan(financial, inputs);
                    result = evaluated.Value; Record(financial.Kind, inputs, result, evaluated.Assumption);
                    if (steps.Count < 63 && evaluated.Schedule?.Count > 0) steps[^1] = steps[^1] with { Schedule = evaluated.Schedule };
                    break;
                }
                case LiteralExpression literal: result = new(literal.Value); break;
                case CurrencyAttachExpression currency:
                    var currencyMagnitude = Real(values.Pop()); result = currencyMagnitude.Kind==SheetValueKind.Earnings?earningsMath.Currency(currencyMagnitude,currency.Currency,moneyMath,true):new(moneyMath.Attach(currencyMagnitude,currency.Currency));
                    Record("currency",[currencyMagnitude],result,"Explicit currency identity; exact magnitude retained; displayed amounts use pinned minor-unit digits"); break;
                case TimeLiteralExpression time: result = new(time.Time); break;
                case AnnualHolidayExpression holiday: result = new(new HolidaySet([new(holiday.Month, holiday.Day)])); break;
                case ResistorLiteralExpression resistor:
                    result = new(electricalMath.Decode(resistor.Bands)); Record("resistor marking", [], result); break;
                case ListExpression list:
                {
                    var items = new SheetValue[list.Items.Length];
                    for (var index = items.Length - 1; index >= 0; index--) items[index] = Nominal(values.Pop());
                    var holidayDates = items.Length > 0 && items.All(value => value.Kind is SheetValueKind.Date or SheetValueKind.HolidayList);
                    result = items.Any(value => value.Kind == SheetValueKind.List) ? new(new SheetMatrix(items.Select(value => value.List))) : holidayDates ? new(new HolidaySet(items.SelectMany(value => value.Kind == SheetValueKind.Date ?
                        new[] { new HolidayDate(value.Date.Month, value.Date.Day, value.Date.Year) } : value.Holidays.Dates))) : new(new SheetList(items));
                    Record(result.Kind == SheetValueKind.Matrix ? "matrix" : holidayDates ? "holiday dates" : "list", items.Take(8).ToArray(), result, result.Kind == SheetValueKind.Matrix ? $"{result.Matrix.RowCount}x{result.Matrix.ColumnCount} immutable rectangular matrix; " + MatrixArithmetic.Convention : holidayDates ? "Annual month/day entries recur; full dates apply once; maximum 256 dates" :
                        items.Length + " numeric/monetary values; flat immutable list; preview may abbreviate; copy includes every formatted value"); break;
                }
                case WorkdayPeriodExpression:
                    var workingCount = Nominal(values.Pop()); result = new(new WorkdayPeriod(WorkdayArithmetic.Count(workingCount), ReadWorkdayCalendar()));
                    Record("working days", [workingCount], result, result.Workdays.Calendar.Scope + "; rules " + WorkdayCalendar.RuleVersion + "; current-rule projection " + result.Workdays.Calendar.FirstYear + "–" + result.Workdays.Calendar.LastYear + "; calendar captured here; " + result.Workdays.Calendar.CustomHolidays.Dates.Count + " custom dates"); break;
                case WorkdayCountExpression:
                    var workTo = Nominal(values.Pop()); var workFrom = Nominal(values.Pop()); var workCalendar = ReadWorkdayCalendar();
                    result = workdayMath.Between(workFrom.Date, workTo.Date, workCalendar);
                    Record("count working days", [workFrom, workTo], result, workCalendar.Scope + "; rules " + WorkdayCalendar.RuleVersion + "; current-rule projection " + workCalendar.FirstYear + "–" + workCalendar.LastYear + "; both endpoints included; reversed range negated; weekends Saturday/Sunday; " + workCalendar.CustomHolidays.Dates.Count + " custom dates"); break;
                case CalendarEventExpression calendarEvent:
                    result = countdowns.Event(calendarEvent); Record("calendar occurrence", [], result, "Upcoming Gregorian date, inclusive of today; weekdays inclusive; no regional holiday observance adjustment"); break;
                case CountdownExpression:
                    var endpoint = Nominal(values.Pop()); result = countdowns.Until(endpoint, out var target, out var expired);
                    Record("countdown", [endpoint], result, (expired ? "Expired; clamped to zero. " : "Elapsed time remaining. ") + "Target " + target + "; " + target.ZoneId + "; " + target.RuleVersion + "; day = 24 elapsed hours"); break;
                case CountdownZoneExpression countdownZone:
                    var deadline = Nominal(values.Pop()); result = timestamps.Zone(deadline, countdownZone.Zone, deadline.Kind == SheetValueKind.ZonedMoment, countdownZone.Ambiguity);
                    Record("countdown target zone", [deadline], result, result.Moment.ZoneId + "; " + result.Moment.RuleVersion); break;
                case NowExpression: result = timestamps.Now(); Record("current instant", [], result, "One host snapshot shared by all lines and nested calls"); break;
                case TimestampJoinExpression:
                    var clock = Nominal(values.Pop()); var calendar = Nominal(values.Pop()); result = calendar.Kind==SheetValueKind.Date && clock.Kind==SheetValueKind.Time ? TimestampArithmetic.Join(calendar,clock) : rateMath.At(calendar,clock);
                    Record(result.Kind==SheetValueKind.LocalTimestamp?"local timestamp":"at rate", [calendar,clock], result, result.Kind==SheetValueKind.LocalTimestamp?"Gregorian date and unzoned clock reading":RateArithmetic.Convention); break;
                case ZoneExpression zone:
                    var local = Nominal(values.Pop()); result = timestamps.Zone(local, zone.Zone, zone.Conversion, zone.Ambiguity);
                    Record(zone.Conversion ? "convert zone" : "resolve zone", [local], result,
                        result.Moment.ZoneId + "; " + result.Moment.RuleVersion + "; skipped times rejected; ambiguity " + (zone.Ambiguity == "" ? "rejected" : zone.Ambiguity)); break;
                case UnitOrZoneExpression choice:
                    var input = Real(values.Pop());
                    result = input.Kind == SheetValueKind.Number ? choice.Conversion ? quantities.Convert(input.Number, choice.Unit) : quantities.Attach(input.Number, choice.Unit) : timestamps.Zone(input, choice.Zone, choice.Conversion, "");
                    Record(choice.Conversion ? "convert" : "attach", [input], result, result.Kind == SheetValueKind.ZonedMoment ? result.Moment.ZoneId + "; " + result.Moment.RuleVersion : "Exact unit definitions"); break;
                case UnixExpression unix:
                    var unixOperand = Nominal(values.Pop()); result = TimestampArithmetic.Unix(unixOperand, unix.Export);
                    Record(unix.Export ? "Unix seconds" : "Unix timestamp", [unixOperand], result, "Exact seconds since 1970-01-01T00:00:00Z; no leap seconds; 100 ns precision"); break;
                case TimeRangeExpression range:
                    var end = Nominal(values.Pop()); var start = Nominal(values.Pop()); result = TimeArithmetic.Range(start, end);
                    Record("clock interval", [start, end], result, "Unzoned wall-clock interval; an earlier same-day endpoint rolls over once; equal endpoints mean zero"); break;
                case DateLiteralExpression date: result = new(date.Date); break;
                case DateAnchorExpression anchor:
                    contextReads.Dependencies |= ContextDependency.Date;
                    result = dates.Anchor(anchor); Record("calendar anchor", [], result, "Host date snapshot; next/last weekdays are strictly future/past"); break;
                case CalendarPeriodExpression period:
                    var count = Nominal(values.Pop()); result = DateArithmetic.MonthPeriod(count, period.MonthsPerUnit);
                    Record("calendar months", [count], result, "Calendar months are not fixed elapsed seconds"); break;
                case DateIntervalExpression interval:
                    var to = Nominal(values.Pop()); var from = Nominal(values.Pop()); result = DateArithmetic.Interval(interval.Kind, from, to);
                    Record(interval.Kind, [from, to], result, interval.Kind == "age" ? "Completed Gregorian anniversaries; February 29 clamps to February 28" : "Signed calendar-day difference; endpoints not both counted"); break;
                case DateShiftExpression shift:
                    var offset = Nominal(values.Pop()); var origin = Nominal(values.Pop()); result = offset.Kind == SheetValueKind.WorkdayPeriod ? workdayMath.Shift(origin.Date, shift.Direction < 0 ? offset.Workdays with { Count = -offset.Workdays.Count } : offset.Workdays) : DateArithmetic.Shift(origin, offset, shift.Direction);
                    Record("relative date", [origin, offset], result, offset.Kind == SheetValueKind.WorkdayPeriod ? offset.Workdays.Calendar.Scope + "; captured rules " + WorkdayCalendar.RuleVersion + "; origin excluded; zero retains origin; weekends/holidays skipped" : "Whole calendar days; months applied before days; month end clamps"); break;
                case NameExpression name: result = resolve(name.Name); Record("reference", [], result, name.Name +
                    (result.Kind == SheetValueKind.Money && result.Money.RateStamp is { } stamp ? "; cached " + stamp.Provider + " rates as of " + stamp.AsOf.ToString("yyyy-MM-dd") : "")); break;
                case UnitExpressionNode unit:
                {
                    var operand = Real(values.Pop());
                result = operand.Kind == SheetValueKind.UsageCount ? rateMath.Attach(operand.UsageCount,unit.Unit,unit.Conversion) : operand.Kind == SheetValueKind.Money ? new SheetValue(unit.Conversion ? moneyMath.ConvertUnit(operand.Money,unit.Unit) : moneyMath.AttachUnit(operand.Money,unit.Unit)) :
                    unit.Conversion ? quantities.Convert(operand.Number, unit.Unit) : quantities.Attach(operand.Number, unit.Unit);
                    Record(unit.Conversion ? "convert unit" : "attach unit", [operand], result,
                        "Exact definitions; dimensions checked; target " + unit.Unit.Symbol + (unit.Unit.FuelForm() != 0 ? "; " + HelperArithmetic.FuelUnits : ""));
                    break;
                }
                case ScaleExpression scale:
                {
                    var operand = Nominal(values.Pop()); result = operand.Kind == SheetValueKind.Complex ? complexMath.Scale(operand, scale.Factor) : operand.Kind is SheetValueKind.UsageCount or SheetValueKind.UsagePrice ? rateMath.Binary("*",operand,new(scale.Factor)) : operand.Kind == SheetValueKind.Money ?
                        new SheetValue(new MoneyValue(quantities.Scale(operand.Money.Magnitude,scale.Factor),operand.Money.Currency,operand.Money.RateStamp,operand.Money.ExactDisplay)) : operand.Kind==SheetValueKind.Earnings?earningsMath.Binary("*",operand,new(scale.Factor)):quantities.Scale(operand.Number, scale.Factor);
                    Record("scale by " + scale.Modifier, [operand, new(scale.Factor)], result, "Exact numeric multiplier; percentage type preserved");
                    break;
                }
                case UnaryExpression unary:
                {
                    var arg = values.Pop();
                    if (integerMath.TryUnary(unary.Operation, arg, out result)) { Record(unary.Operation, [arg], result, IntegerArithmetic.Convention); break; }
                    arg = Nominal(arg);
                    if (arg.Kind == SheetValueKind.Prime) throw new ArithmeticException(PrimeArithmetic.NotNumeric);
                    if (arg.Kind == SheetValueKind.Complex) { result = complexMath.Unary(unary.Operation, arg); Record(unary.Operation, [arg], result, ComplexArithmetic.Convention); break; }
                    if(arg.Kind is SheetValueKind.UsageCount or SheetValueKind.UsagePrice){result=rateMath.Unary(unary.Operation,arg);Record(unary.Operation,[arg],result,RateArithmetic.Convention);break;}
                    if (MatrixArithmetic.IsCollection(arg)) { result = matrixMath.Unary(unary.Operation, arg); Record(unary.Operation, [arg], result, MatrixArithmetic.Convention); break; }
                    if (unary.Operation == "!" && arg.Kind == SheetValueKind.Number && arg.Number.IsApproximate) throw new ArithmeticException("Factorial requires an exact integer");
                    if(arg.Kind==SheetValueKind.Earnings) { result=earningsMath.Unary(unary.Operation,arg); Record(unary.Operation,[arg],result); break; }
                    if (arg.Kind == SheetValueKind.Money) { result = new(moneyMath.Unary(unary.Operation,arg.Money)); Record(unary.Operation,[arg],result); break; }
                    if (arg.Kind == SheetValueKind.WorkdayPeriod)
                    {
                        if (unary.Operation is not "+" and not "-") throw new ArithmeticException("Unsupported working-day unary operation");
                        result = new(unary.Operation == "-" ? arg.Workdays with { Count = -arg.Workdays.Count } : arg.Workdays);
                        Record(unary.Operation, [arg], result); break;
                    }
                    if (arg.Kind == SheetValueKind.Time) throw new ArithmeticException("A clock reading cannot use a unary numeric operator");
                    result = arg.Kind != SheetValueKind.Number ? unary.Operation == "-" ? DateArithmetic.Negate(arg) :
                        unary.Operation == "+" && arg.Kind == SheetValueKind.CalendarPeriod ? arg : throw new ArithmeticException("Invalid date/calendar unary operation") :
                        unary.Operation == "!" ? new(Factorial(arg.Scalar, cancellationToken)) : quantities.Unary(unary.Operation, arg.Number);
                    Record(unary.Operation, [arg], result); break;
                }
                case BinaryExpression binary:
                {
                    var right = values.Pop(); var left = values.Pop();
                    if (left.Kind == SheetValueKind.Prime || right.Kind == SheetValueKind.Prime) throw new ArithmeticException(PrimeArithmetic.NotNumeric);
                    if (complexMath.Applies(binary.Operation, left, right))
                    { left = Nominal(left); right = Nominal(right); result = complexMath.Binary(binary.Operation, left, right); Record(binary.Operation, [left, right], result, ComplexArithmetic.Convention); break; }
                    if (left.Kind == SheetValueKind.Network || right.Kind == SheetValueKind.Network)
                    {
                        if (binary.Operation != "/" || left.Kind != SheetValueKind.Network || left.Network.Form != NetworkForm.Address) throw new ArithmeticException("Network values do not support numeric arithmetic; use explicit network functions");
                        result = networkMath.Attach(left, right); Record("CIDR subnet", [left, right], result, NetworkArithmetic.Convention); break;
                    }
                    if(left.Kind is SheetValueKind.UsageCount or SheetValueKind.UsagePrice || right.Kind is SheetValueKind.UsageCount or SheetValueKind.UsagePrice)
                    {result=rateMath.Binary(binary.Operation,left,right);Record(binary.Operation,[left,right],result,RateArithmetic.Convention);break;}
                    if(binary.Operation=="/"&&left.Kind==SheetValueKind.Number&&left.Unit?.Dimension==RateArithmetic.Data&&right.Kind==SheetValueKind.Number&&right.Unit?.Dimension==TimeArithmetic.TimeDimension)
                    {result=rateMath.Throughput(left,right);Record("throughput",[left,right],result,RateArithmetic.Convention+"; two-decimal rate presentation retains exact magnitude");break;}
                    if (integerMath.TryBinary(binary.Operation, left, right, out result)) { Record(binary.Operation, [left, right], result, IntegerArithmetic.Convention); break; }
                    right = Nominal(right); left = Nominal(left);
                    if (binary.Operation == "||") { result = electricalMath.Parallel([left, right]); Record("parallel", [left, right], result, ElectricalArithmetic.ParallelAssumption); break; }
                    if (MatrixArithmetic.IsCollection(left) || MatrixArithmetic.IsCollection(right))
                    { result = matrixMath.Binary(binary.Operation, left, right); Record(binary.Operation, [left, right], result, MatrixArithmetic.Convention); break; }
                    var relative = !left.IsPercentage && right.IsPercentage && binary.Operation is "+" or "-";
                    result = left.Kind==SheetValueKind.Earnings || right.Kind==SheetValueKind.Earnings?earningsMath.Binary(binary.Operation,left,right):
                        left.Kind == SheetValueKind.Money || right.Kind == SheetValueKind.Money ? moneyMath.Binary(binary.Operation,left,right) :
                        left.Kind == SheetValueKind.WorkdayPeriod || right.Kind == SheetValueKind.WorkdayPeriod ? workdayMath.Binary(binary.Operation, left, right) :
                        TimestampArithmetic.IsTimestamp(left) || TimestampArithmetic.IsTimestamp(right) ? TimestampArithmetic.Binary(binary.Operation, left, right) :
                        left.Kind == SheetValueKind.Time || right.Kind == SheetValueKind.Time ? TimeArithmetic.Binary(binary.Operation, left, right) :
                        left.Kind == SheetValueKind.Number && right.Kind == SheetValueKind.Number ? quantities.Binary(binary.Operation, left.Number, right.Number) : dates.Binary(binary.Operation, left, right);
                    if (binary.Operation is "*" or "/" or "of") result = ElectricalArithmetic.PreferElectricalUnit(left, right, result);
                    Record(binary.Operation, [left, right], result, left.Kind==SheetValueKind.Earnings || right.Kind==SheetValueKind.Earnings?earningsMath.Assumption ?? "Typed earnings arithmetic; calendar and elapsed durations remain distinct; daily earnings use an 8-hour working day":left.Kind == SheetValueKind.Money || right.Kind == SheetValueKind.Money ? moneyMath.Provenance ?? "Exact monetary arithmetic; display rounding does not replace source amounts" : left.Kind == SheetValueKind.WorkdayPeriod || right.Kind == SheetValueKind.WorkdayPeriod ?
                        (left.Kind == SheetValueKind.WorkdayPeriod ? left.Workdays : right.Workdays).Calendar.Scope + "; captured rules " + WorkdayCalendar.RuleVersion + "; shift excludes origin, zero retains origin; weekends/holidays skipped; not elapsed time" : relative ? "Percentage change relative to the left operand" : null); break;
                }
                case CallExpression call:
                {
                    var args = new SheetValue[call.Arguments.Length];
                    for (var i = args.Length - 1; i >= 0; i--) args[i] = values.Pop();
                    if (RateArithmetic.IsFunction(call.Name)) { result=rateMath.Function(call.Name,args.Select(Nominal).ToArray());Record(call.Name,args,result,result.Kind==SheetValueKind.UptimeBudget?result.UptimeBudget.Details:RateArithmetic.Convention);break; }
                    if (DeveloperArithmetic.IsFunction(call.Name)) { result = developerMath.Function(call.Name, args); Record(call.Name, args, result, DeveloperArithmetic.Convention); break; }
                    if (TextArithmetic.IsFunction(call.Name))
                    {
                        var textResult = textMath.Function(call.Name, args); result = textResult.Value;
                        Record(call.Name, args, result, TextArithmetic.Convention);
                        if (steps.Count < 63) steps[^1] = steps[^1] with { TextTransform = textResult.Evidence }; break;
                    }
                    if (NetworkArithmetic.IsFunction(call.Name)) { result = networkMath.Function(call.Name, args); Record(call.Name, args, result, NetworkArithmetic.Convention); break; }
                    if (IntegerArithmetic.IsFunction(call.Name)) { result = integerMath.Function(call.Name, args); Record(call.Name, args, result, IntegerArithmetic.Convention); break; }
                    if (HelperArithmetic.IsFunction(call.Name)) { args = args.Select(Nominal).ToArray(); var computed = helperMath.Function(call.Name, args); result = computed.Value; Record(computed.Operation, args, result, computed.Assumption); break; }
                    if (TableArithmetic.IsFunction(call.Name)) { var selected = TableArithmetic.Function(call.Name, args); result = selected.Value; Record(call.Name, args, result, selected.Assumption); break; }
                    if (EquationSyntax.Function(call.Name)) { result = formulaMath.SolutionFunction(call.Name, args.Select(Nominal).ToArray()); Record(call.Name, args, result, "Root taken from the retained solve result; order ascending"); break; }
                    if (FormulaFunctions.IsSheetFunction(call.Name)) { args = args.Select(Nominal).ToArray(); result = formulaMath.SheetFunction(call.Name, args); Record(call.Name, args, result, FormulaFunctions.Convention + "; 12 significant digits"); break; }
                    if (call.Name.Equals("engineering", StringComparison.OrdinalIgnoreCase))
                    { result = practicalMath.Engineering(args.Select(Nominal).ToArray()); Record(call.Name, args, result, PracticalArithmetic.EngineeringAssumption); break; }
                    if (call.Name.Equals("weightedMean", StringComparison.OrdinalIgnoreCase))
                    {
                        PracticalArithmetic.ValidateArity(call.Name, args.Length);
                        result = practicalMath.Grades(args[0].List.Values.Select(Nominal).ToArray(), args[1].List.Values.Select(Nominal).ToArray());
                        Record(call.Name, args, result, "Weighted mean sum(score*weight) / sum(weight); no grading range or pass threshold inferred; exact represented magnitudes, four-decimal display"); break;
                    }
                    if (ElectricalArithmetic.IsFunction(call.Name))
                    {
                        ElectricalArithmetic.ValidateArity(call.Name, args.Length);
                        if (call.Name.Equals("parallel", StringComparison.OrdinalIgnoreCase))
                        { result = electricalMath.Parallel(args.Select(Nominal).ToArray()); Record(call.Name, args, result, ElectricalArithmetic.ParallelAssumption); }
                        else { result = new(electricalMath.Encode(args, call.Name.Equals("resistorColors", StringComparison.OrdinalIgnoreCase))); Record(call.Name, args, result); }
                        break;
                    }
                    if (FunctionLibrary.IsBuiltin(call.Name)) args = args.Select(Nominal).ToArray();
                    if (complexMath.Applies(call.Name, args)) { result = complexMath.Function(call.Name, args); Record(call.Name, args, result, ComplexArithmetic.Convention); break; }
                    if (PrimeArithmetic.IsFunction(call.Name)) { var primed = primeMath.Function(call.Name, args); result = primed.Value; Record(call.Name, args, result, primed.Evidence); break; }
                    if (MatrixArithmetic.IsFunction(call.Name))
                    { result = matrixMath.Function(call.Name, args); Record(call.Name, args, result, MatrixArithmetic.Convention); break; }
                    if(RomanianTaxArithmetic.IsFunction(call.Name))
                    {
                        var evaluated=new RomanianTaxArithmetic(budget,cancellationToken).Function(call.Name,args);
                        result=evaluated.Value; Record(call.Name,args,result,evaluated.Assumption);
                        if(steps.Count<63) steps[^1]=steps[^1] with{RomanianTax=evaluated.Evidence};
                        break;
                    }
                    if (StatisticsArithmetic.IsFunction(call.Name))
                    {
                        var evaluated = new StatisticsArithmetic(math, budget, cancellationToken, moneyMath).Function(call.Name, args);
                        result = evaluated.Value; Record(call.Name, args, result, evaluated.Assumption); break;
                    }
                    if (FinancialArithmetic.IsFunction(call.Name))
                    {
                        var evaluated = new FinancialArithmetic(budget, cancellationToken, moneyMath).Function(call.Name, args);
                        result = evaluated.Value; Record(call.Name, args, result, evaluated.Assumption);
                        if (steps.Count < 63 && evaluated.Irr is not null) steps[^1] = steps[^1] with { Irr=evaluated.Irr };
                        if (steps.Count < 63 && evaluated.Growth is not null) steps[^1] = steps[^1] with { Growth=evaluated.Growth };
                        break;
                    }
                    if(call.Name.Equals("abs",StringComparison.OrdinalIgnoreCase) && args.Length==1 && args[0].Kind==SheetValueKind.Earnings)
                    {
                        var rate=args[0].Earnings; var amount=rate.Amount.Kind==SheetValueKind.Money?moneyMath.Function("abs",[rate.Amount]):new SheetValue(quantities.Function("abs",[rate.Amount.Number]));
                        result=new(new EarningsValue(amount,rate.Period));
                    }
                    else if (FunctionLibrary.IsBuiltin(call.Name)) result = args.Any(value => value.Kind == SheetValueKind.Money) ? moneyMath.Function(call.Name,args) : quantities.Function(call.Name, args.Select(value => value.Number).ToArray());
                    else throw new FormatException("User functions are dispatched outside the primitive operation frame");
                    Record(call.Name, args, result, moneyMath.Provenance ?? describeFunction?.Invoke(call.Name)); break;
                }
                case AggregateExpression total:
                {
                    var scalarSources = aggregate.Where(value => !ExcludedFromAggregate(value)).Select(Nominal).ToArray();
                    result = scalarSources.Any(value=>value.Kind is SheetValueKind.UsageCount or SheetValueKind.UsagePrice)?rateMath.Aggregate(scalarSources,total.Average):scalarSources.Any(value=>value.Kind==SheetValueKind.Earnings)?earningsMath.Aggregate(scalarSources,total.Average):scalarSources.Any(value => value.Kind == SheetValueKind.Money) ? new SheetValue(moneyMath.Aggregate(scalarSources,total.Average,cancellationToken)) : quantities.Aggregate(scalarSources.Select(value => value.Number).ToArray(), total.Average, cancellationToken);
                    Record(total.Average ? "average" : "sum", scalarSources.Take(8).ToArray(), result, $"{scalarSources.Length} source lines; aggregate result, list/matrix data, solve, complex, prime, table and figure lines excluded" + (moneyMath.Provenance is { } provenance ? "; " + provenance : "")); break;
                }
                case RoundingExpression rounding:
                {
                    var precision = Nominal(values.Pop()); var operand = Nominal(values.Pop());
                    result = operand.Kind == SheetValueKind.Complex ? complexMath.Round(rounding.Kind, operand, precision.Number) : operand.Kind is SheetValueKind.UsageCount or SheetValueKind.UsagePrice ? rateMath.Round(rounding.Kind,operand,precision) : MatrixArithmetic.IsCollection(operand) ? matrixMath.Round(rounding.Kind, operand, precision) : operand.Kind==SheetValueKind.Earnings?earningsMath.Round(rounding.Kind,operand,precision):operand.Kind == SheetValueKind.Money ? new SheetValue(moneyMath.Round(rounding.Kind,operand.Money,precision,cancellationToken)) : quantities.Round(rounding.Kind, operand.Number, precision.Number, cancellationToken);
                    var operation = rounding.Kind switch
                    {
                        RoundingKind.DecimalPlaces => "round to decimal places",
                        RoundingKind.Increment => "round to increment",
                        _ => "round to significant figures"
                    };
                    Record(operation, [operand, precision], result, "Exact arithmetic; halfway cases round away from zero" + (moneyMath.Provenance is { } provenance ? "; " + provenance : "") +
                        (operand.IsPercentage && rounding.Kind != RoundingKind.Increment ? "; precision applies to percentage points" : ""));
                    break;
                }
                default: throw new FormatException("Unknown expression");
            }
            return result;
        }
        SheetValue ConvertCurrency(CurrencyConvertExpression currency)
        {
                    SheetValue source;
                    var converter = moneyMath;
                    if (currency.Date is not null)
                    {
                        var date = values.Pop().Date;
                        contextReads.Dependencies |= ContextDependency.Date;
                        if (context.Today is { } today && date > today) throw new ArithmeticException("Future historical currency rates are unavailable");
                        var datedContext = context with { CurrencyDate = date };
                        var evaluated = Evaluate(currency.Operand,resolve,aggregate,cancellationToken,userFunction,budget,describeFunction,datedContext,contextReads);
                        source = evaluated.Value;
                        foreach (var step in evaluated.Steps) { if (steps.Count >= 62) break; steps.Add(step); }
                        converter = new MoneyArithmetic(math,datedContext,contextReads);
                    }
                    else source = Nominal(values.Pop());
                    if(source.Kind==SheetValueKind.Earnings && currency.Unit is not null) throw new ArithmeticException("Convert earnings periods with in hourly/daily/monthly/yearly separately from currency conversion");
                    var result = source.Kind==SheetValueKind.UsagePrice ? new SheetValue(new UsagePriceValue(converter.Convert(source.UsagePrice.Amount,currency.Currency,currency.Unit),source.UsagePrice.PerCount,source.UsagePrice.Kind)) : source.Kind==SheetValueKind.Earnings?earningsMath.Currency(source,currency.Currency,converter):new(converter.Convert(source.Money,currency.Currency,currency.Unit));
                    Record("convert currency",[source],result,converter.Provenance ?? "Identity currency conversion; no rate lookup"); return result;
        }
        while (stack.TryPop(out var frame))
        {
            budget.Step(cancellationToken);
            if (!frame.Ready)
            {
                stack.Push((frame.Node, true));
                var children = frame.Node is CurrencyConvertExpression { Date: { } currencyDate } ? new[] { currencyDate } : Children(frame.Node);
                foreach (var child in children.Reverse()) stack.Push((child, false));
                continue;
            }
            SheetValue result;
            if (frame.Node is CallExpression call && !FunctionLibrary.IsBuiltin(call.Name))
            {
                var args = new SheetValue[call.Arguments.Length];
                for (var i = args.Length - 1; i >= 0; i--) args[i] = values.Pop();
                var callContext = context.Uuids is null ? context : context with { UuidPath = context.UuidPath + "/" + call.Site.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":" + call.Name.ToUpperInvariant() };
                var invoked = userFunction?.Invoke(call.Name, args, callContext) ?? throw new FormatException($"Unknown function: {call.Name}");
                result = invoked.Value;
                foreach (var step in invoked.Steps) { if (steps.Count >= 62) break; steps.Add(step); }
                Record(call.Name, args, result, moneyMath.Provenance ?? describeFunction?.Invoke(call.Name));
            }
            else if (frame.Node is CurrencyConvertExpression currency) result = ConvertCurrency(currency);
            else result = EvaluateNode(frame.Node);
            _ = result.Display; // Bound presentation before publishing a successful result.
            values.Push(result);
        }
        var answer = values.Pop();
        if (steps.Count == 63) steps.Add(new("result", [], Preview(answer.Display), "Explanation limited to 63 operations"));
        if (steps.Count == 0) steps.Add(new("literal", [], Preview(answer.Display)));
        return (answer, steps.ToArray());
    }
    private static Rational Factorial(Rational value, CancellationToken token)
    {
        if (value.Denominator != 1 || value.Numerator < 0 || value.Numerator > 500) throw new ArithmeticException("Factorial requires an integer from 0 to 500");
        var result = BigInteger.One;
        for (var i = 2; i <= (int)value.Numerator; i++) { token.ThrowIfCancellationRequested(); result *= i; }
        return new(result, 1);
    }
}
