import Foundation

typealias UserFunction = (String, [SheetValue], EvaluationContext) throws -> (value: SheetValue, steps: [CalculationStep])

enum ExpressionEvaluation {
    static func children(_ expression: Expression) -> [Expression] { expression.children }
    static func sheetAggregate(_ expression: Expression?) -> AggregateExpression? {
        var expression = expression
        while true {
            switch expression {
            case let e as UsageConvertExpression: expression = e.operand
            case let e as IntegerConvertExpression: expression = e.operand
            case let e as RoundingExpression: expression = e.operand
            case let e as UnitExpressionNode: expression = e.operand
            case let e as CurrencyConvertExpression: expression = e.operand
            case let e as EarningsConvertExpression: expression = e.operand
            case let e as EngineeringExpression: expression = e.operand
            default: return expression as? AggregateExpression
            }
        }
    }
    /// Kinds that sum/average skip, never crash: lists and matrices are data lines; add a non-scalar kind here.
    static func excludedFromAggregate(_ value: SheetValue) -> Bool {
        if MatrixArithmetic.isCollection(value) { return true }
        switch value {
        case .equation, .complex, .prime, .plot, .chart, .table: return true
        case .practical(let p): return p.original == nil
        default: return false
        }
    }
    /// Lines that present data rather than contribute a value to their block, so an error on one never reaches sum or average.
    static func isPresentation(_ expression: Expression?) -> Bool { expression is PlotExpression || expression is ChartExpression || expression is TableExpression }
    /// Depth-first, last child first (C#'s stack walk order).
    static func walk(_ expression: Expression) -> [Expression] {
        var stack: [Expression] = [expression]; var result: [Expression] = []
        while let node = stack.popLast() { result.append(node); stack.append(contentsOf: node.children) }
        return result
    }
    static func evaluate(_ expression: Expression, _ resolve: @escaping (String) throws -> SheetValue, _ aggregate: [SheetValue], _ cancellationToken: CancellationToken,
                         _ userFunction: UserFunction? = nil, _ budget: ExecutionBudget? = nil, _ describeFunction: ((String) -> String?)? = nil,
                         _ context: EvaluationContext? = nil, _ contextReads: ContextReads? = nil) throws -> (value: SheetValue, steps: [CalculationStep]) {
        let budget = budget ?? ExecutionBudget()
        try budget.enterScope()
        defer { budget.leaveScope() }
        let frame = Evaluator(expression, resolve, aggregate, cancellationToken, userFunction, budget, describeFunction, context ?? EvaluationContext(), contextReads ?? ContextReads())
        return try frame.run()
    }
    static func factorial(_ value: Rational, _ token: CancellationToken) throws -> Rational {
        if !value.denominator.isOne || value.numerator < 0 || value.numerator > 500 { throw CalcError.arithmetic("Factorial requires an integer from 0 to 500") }
        var result = BigInt.one
        let n = value.numerator.intValue!
        if n >= 2 { for i in 2...n { try token.throwIfCancellationRequested(); result = result * BigInt(i) } }
        return try Rational(result)
    }
    static func preview(_ text: String) -> String { text.netLength <= 96 ? text : text.netSubstring(0, 96) + "…" }
}

/// One evaluation's working state (the locals and local functions of C# ExpressionEvaluation.Evaluate).
private final class Evaluator {
    let expression: Expression
    let resolve: (String) throws -> SheetValue
    let aggregate: [SheetValue]
    let cancellationToken: CancellationToken
    let userFunction: UserFunction?
    let budget: ExecutionBudget
    let describeFunction: ((String) -> String?)?
    let context: EvaluationContext
    let contextReads: ContextReads
    var values: [SheetValue] = []
    var steps: [CalculationStep] = []
    let math: ExactArithmetic, quantities: QuantityArithmetic, dates: DateArithmetic, timestamps: TimestampArithmetic, countdowns: CountdownArithmetic
    let textMath: TextArithmetic, developerMath: DeveloperArithmetic, networkMath: NetworkArithmetic, integerMath: IntegerArithmetic
    let practicalMath: PracticalArithmetic, chemistryMath: ChemistryArithmetic, electricalMath: ElectricalArithmetic, matrixMath: MatrixArithmetic
    let workdayMath: WorkdayArithmetic, moneyMath: MoneyArithmetic, rateMath: RateArithmetic, earningsMath: EarningsArithmetic
    let formulaMath: FormulaArithmetic, complexMath: ComplexArithmetic, primeMath: PrimeArithmetic, helperMath: HelperArithmetic

    init(_ expression: Expression, _ resolve: @escaping (String) throws -> SheetValue, _ aggregate: [SheetValue], _ cancellationToken: CancellationToken,
         _ userFunction: UserFunction?, _ budget: ExecutionBudget, _ describeFunction: ((String) -> String?)?, _ context: EvaluationContext, _ contextReads: ContextReads) {
        self.expression = expression; self.resolve = resolve; self.aggregate = aggregate; self.cancellationToken = cancellationToken
        self.userFunction = userFunction; self.budget = budget; self.describeFunction = describeFunction; self.context = context; self.contextReads = contextReads
        math = ExactArithmetic(budget, cancellationToken); quantities = QuantityArithmetic(math); dates = DateArithmetic(context)
        timestamps = TimestampArithmetic(context, contextReads); countdowns = CountdownArithmetic(context, contextReads)
        textMath = TextArithmetic(budget, cancellationToken); developerMath = DeveloperArithmetic(budget, cancellationToken)
        networkMath = NetworkArithmetic(budget, cancellationToken); integerMath = IntegerArithmetic(budget, cancellationToken)
        practicalMath = PracticalArithmetic(math, budget, cancellationToken); chemistryMath = ChemistryArithmetic(budget, cancellationToken)
        electricalMath = ElectricalArithmetic(math, budget, cancellationToken); matrixMath = MatrixArithmetic(math, budget, cancellationToken)
        workdayMath = WorkdayArithmetic(budget, cancellationToken); moneyMath = MoneyArithmetic(math, context, contextReads)
        rateMath = RateArithmetic(math, budget, cancellationToken, moneyMath)
        earningsMath = EarningsArithmetic(math, moneyMath, workdayMath, context, contextReads, cancellationToken)
        formulaMath = FormulaArithmetic(math, budget, cancellationToken); complexMath = ComplexArithmetic(math, quantities, budget, cancellationToken)
        primeMath = PrimeArithmetic(math, budget, cancellationToken); helperMath = HelperArithmetic(math, budget, context, contextReads, cancellationToken)
    }

    func pop() -> SheetValue { values.removeLast() }
    func popInputs(_ count: Int) throws -> [SheetValue] {
        var inputs = [SheetValue](repeating: .number(NumericValue()), count: count)
        var i = count - 1
        while i >= 0 { inputs[i] = try nominal(pop()); i -= 1 }
        return inputs
    }
    func readWorkdayCalendar() throws -> WorkdayCalendar {
        contextReads.dependencies.insert(.workdayCalendar)
        return try WorkdayCalendar(context.workdayRegion, context.customHolidays)
    }
    static func approximate(_ value: SheetValue) -> Bool {
        switch value {
        case .plot: return true
        case .chart(let v): return v.isApproximate
        case .practical(let v): return v.isApproximate
        case .complex(let v): return v.isApproximate
        case .equation(let v): return v.isApproximate
        case .engineering(let v): return v.original.isApproximate
        case .number(let v): return v.isApproximate
        case .money(let v): return v.magnitude.isApproximate
        case .list(let v): return v.isApproximate
        case .matrix(let v): return v.isApproximate
        case .earnings(let v): return approximate(v.amount)
        case .usageCount(let v): return v.quantity.isApproximate
        case .usagePrice(let v): return v.amount.magnitude.isApproximate
        default: return false
        }
    }
    func record(_ op: String, _ args: [SheetValue], _ result: SheetValue, _ assumption: String? = nil) throws {
        var assumption = assumption
        if let a = assumption, a.hasPrefix(RateArithmetic.convention) {
            assumption = a + "\n" + (try args.prefix(8).enumerated().map { "Input " + String($0.offset + 1) + ": " + (try RateArithmetic.evidence($0.element)) }).joined(separator: "\n") +
                "\nResult: " + (try RateArithmetic.evidence(result))
        }
        if case .resistor(let resistor) = result { assumption = (assumption.map { $0 + "; " } ?? "") + (try ElectricalArithmetic.markingAssumption(resistor)) }
        if Evaluator.approximate(result) || args.contains(where: Evaluator.approximate) { assumption = "Approximate input/result; " + (assumption ?? "") }
        if steps.count < 63 { steps.append(CalculationStep(op, try args.map { ExpressionEvaluation.preview(try $0.display) }, ExpressionEvaluation.preview(try result.display), assumption)) }
    }
    /// Attaches evidence to the step just recorded (C# `steps[^1] = steps[^1] with { … }`).
    func amendLastStep(_ change: (CalculationStep) -> Void) { if steps.count < 63, let last = steps.last { steps[steps.count - 1] = last.copy(change) } }
    func nominal(_ value: SheetValue) throws -> SheetValue {
        switch value {
        case .uptimeBudget(let b):
            let duration = try rateMath.nominal(b); try record("uptime budget duration", [value], duration, try b.details); return duration
        case .integer(let integer):
            try budget.step(cancellationToken); let original = SheetValue(try Rational(integer.value))
            try record("integer magnitude", [value], original, "Exact interpreted word value used; word/base profile leaves integer arithmetic"); return original
        case .engineering(let engineering):
            try budget.step(cancellationToken); let original = SheetValue.number(engineering.original)
            try record("engineering source magnitude", [value], original, "Exact represented value used; engineering presentation rounding is not a change to the stored magnitude"); return original
        case .practical(let practical) where practical.original != nil:
            try budget.step(cancellationToken); let original = SheetValue.number(practical.original!)
            try record("practical magnitude", [value], original, "Exact value used; m:ss, h:mm:ss and pace presentation round to whole seconds for display only"); return original
        case .resistor(let resistor):
            try budget.step(cancellationToken); let nominal = SheetValue.number(resistor.nominal)
            try record("nominal resistance", [value], nominal, try ElectricalArithmetic.nominalAssumption(resistor)); return nominal
        default: return value
        }
    }
    /// Units and money never attach to a complex value.
    func real(_ value: SheetValue) throws -> SheetValue {
        let value = try nominal(value)
        if value.kind == .complex { throw CalcError.arithmetic(ComplexArithmetic.refusal) }
        return value
    }

    func evaluateNode(_ currentNode: Expression) throws -> SheetValue {
        var result: SheetValue
        switch currentNode {
        case let equation as EquationExpression:
            let inputs = try popInputs(equation.inputs.count)
            let solved = try formulaMath.solve(equation, inputs); result = solved.value
            try record("solve for " + equation.variable, Array(inputs.prefix(8)), result, solved.assumption)
        case let integral as IntegralExpression:
            let inputs = try popInputs(integral.inputs.count)
            let integrated = try formulaMath.integrate(integral, inputs); result = integrated.value
            try record("integral over " + integral.variable, Array(inputs.prefix(8)), result, integrated.assumption)
        case let derivative as DerivativeExpression:
            let inputs = try popInputs(derivative.inputs.count)
            let differentiated = try formulaMath.differentiate(derivative, inputs); result = differentiated.value
            try record("derivative in " + derivative.variable, Array(inputs.prefix(8)), result, differentiated.assumption)
        case let helper as HelperExpression:
            let inputs = try popInputs(helper.operands.count)
            let computed = try helperMath.evaluate(helper, inputs); result = computed.value
            try record(computed.operation, Array(inputs.prefix(8)), result, computed.assumption)
        case let constant as ConstantExpression:
            guard let entry = ConstantCatalog.tryFind(constant.name) else { throw CalcError.format("Unknown constant: " + constant.name) }
            try budget.step(cancellationToken); result = .number(try ConstantCatalog.resolve(entry, constant.magnitude))
            try record(constant.name, [], result, entry.assumption + (constant.magnitude ? ConstantCatalog.formulaNote : ""))
        case let imaginary as ImaginaryExpression: result = try ComplexArithmetic.literal(imaginary.coefficient)
        case let plot as PlotExpression:
            let inputs = try popInputs(plot.inputs.count)
            let sampled = try PlotArithmetic.plot(plot, inputs, math, budget, cancellationToken); result = sampled.value
            try record("plot", Array(inputs.prefix(8)), result, sampled.assumption)
        case let chart as ChartExpression:
            let data: SheetValue? = chart.data == nil ? nil : try nominal(pop())
            let built = try ChartArithmetic(math, budget, cancellationToken, moneyMath).build(chart.kind, data, try aggregate.map(nominal), context.aggregateLabels)
            result = built.value; try record("chart", data.map { [$0] } ?? [], result, built.assumption)
        case let table as TableExpression:
            result = .table(table.value); try record("table", [], result, table.value.summary.netReplace("\n", "; "))
        case let conversion as UsageConvertExpression:
            let convertedUsage = pop(); result = try rateMath.convertCount(try convertedUsage.usageCount, conversion.kind, conversion.unit)
            try record("usage rate conversion", [convertedUsage], result, RateArithmetic.convention)
        case let usage as UsageCountExpression:
            let usageInput = try nominal(pop()); result = try rateMath.count(usageInput, usage.kind)
            try record("usage count", [usageInput], result, RateArithmetic.convention)
        case let price as UsagePriceExpression:
            let priceInput = pop(); result = try rateMath.price(priceInput, price.perCount, price.kind)
            try record("usage price", [priceInput], result, RateArithmetic.convention)
        case is RateForExpression:
            let rateDuration = try nominal(pop()); let elapsedRate = pop(); result = try rateMath.forDuration(elapsedRate, rateDuration)
            try record("elapsed rate total", [elapsedRate, rateDuration], result, RateArithmetic.convention + "; fixed elapsed days are 24 hours; no tiers, taxes or calendar billing inferred")
        case let uuid as UuidExpression:
            contextReads.dependencies.insert(.uuid)
            guard let uuids = context.uuids else { throw CalcError.arithmetic("UUID requires a document generation context") }
            result = .text(try TextValue(try uuids.resolve(context.uuidLine, context.uuidPath, uuid.site, contextReads)))
            try record("uuid", [], result, "Stable version-4 UUID; editing this expression generates a new value; other expressions, reevaluation and saved-sheet restart retain it; not a security token")
        case let dice as DiceExpression:
            contextReads.dependencies.insert(.dice)
            let roll = context.uuidPath.isEmpty ? context.uuids?.dice(context.uuidLine) : nil
            guard let roll, roll.formula == dice.formula.notation, dice.formula.fits(roll.faces) else {
                let preview = try DiceSyntax.preview(dice.formula); throw DiceUnrolledError(preview: preview.preview, steps: preview.steps)
            }
            try budget.step(cancellationToken)
            let rolled = try DiceSyntax.total(dice.formula, roll.faces)
            result = SheetValue(Rational(rolled.total)); for step in rolled.steps where steps.count < 63 { steps.append(step) }
        case let colour as ColourLiteralExpression: result = try developerMath.colourLiteral(colour.text)
        case let textLiteral as TextLiteralExpression: result = try textMath.literal(textLiteral.value)
        case let ip as IpLiteralExpression: result = try networkMath.literal(ip.text)
        case let mask as PrefixMaskExpression:
            result = try networkMath.prefixMask(mask.prefix, mask.family); try record("network mask", [], result, NetworkArithmetic.convention)
        case is NetworkMembershipExpression:
            let networkTarget = pop(); let networkCandidate = pop(); result = try networkMath.contains(networkCandidate, networkTarget)
            try record("network membership", [networkCandidate, networkTarget], result, NetworkArithmetic.convention)
        case let integer as IntegerLiteralExpression: result = try integerMath.literal(integer.text)
        case let integer as IntegerConvertExpression:
            let integerInput = pop()
            let colourConversion = integerInput.kind == .colour && integer.radix == 16 && integer.width == nil
            result = colourConversion ? try developerMath.function("colourhex", [integerInput]) : try integerMath.convert(integerInput, integer.radix, integer.width, integer.signed)
            try record(colourConversion ? "colour hex presentation" : "integer conversion", [integerInput], result, colourConversion ? DeveloperArithmetic.convention : IntegerArithmetic.convention)
        case let chemistry as ChemistryExpression:
            let chemicalInput: SheetValue? = chemistry.amount == nil ? nil : try nominal(pop())
            let evaluated = try chemistryMath.evaluate(chemistry, chemicalInput); result = evaluated.value
            try record(chemistry.amount == nil ? "molar mass" : "chemical mass/amount", chemicalInput.map { [$0] } ?? [], result,
                       ChemistryArithmetic.assumption + "; " + evaluated.evidence.formula + "; " + evaluated.evidence.ruleId)
            amendLastStep { $0.chemistry = evaluated.evidence }
        case is EngineeringExpression:
            let engineeringInput = try nominal(pop()); result = try practicalMath.engineering([engineeringInput])
            try record("engineering notation", [engineeringInput], result, PracticalArithmetic.engineeringAssumption)
        case let grades as GradesExpression:
            let weights = try popInputs(grades.weights.count); let scores = try popInputs(grades.scores.count)
            result = try practicalMath.grades(scores, weights)
            try record("weighted grades", Array(scores.prefix(8)), result, "Weighted mean sum(score*weight) / sum(weight); nonnegative weights, no grading range or pass threshold inferred; exact represented magnitudes, four-decimal display")
        case let salary as SalaryExpression:
            let salaryInput = try nominal(pop())
            let salaryResult = try PayrollArithmetic(budget, cancellationToken, moneyMath, context, contextReads).evaluate(salary, salaryInput)
            result = salaryResult.value
            try record(salary.employerCost ? "salary employer cost" : salary.inverse ? "salary net to gross" : "salary gross to net", [salaryInput], result, salaryResult.assumption)
            amendLastStep { $0.payroll = salaryResult.evidence }
        case let earnings as EarningsAttachExpression:
            let earningsAmount = try real(pop()); result = .earnings(try EarningsValue(earningsAmount, earnings.period))
            try record("earnings period", [earningsAmount], result, "Calendar earnings rate; month/year is not a fixed elapsed duration")
        case let earnings as EarningsConvertExpression:
            let earningsSource = try nominal(pop()); result = try earningsMath.convert(earningsSource, earnings.period)
            try record("convert earnings", [earningsSource], result, earningsMath.assumption)
        case is InvoiceDueExpression:
            let invoiceDays = try nominal(pop()); let invoiceDate = try nominal(pop()); result = try FinancialArithmetic.invoiceDue(invoiceDate, invoiceDays)
            try record("invoice due date", [invoiceDate, invoiceDays], result, "Net terms; whole Gregorian calendar days after issue date; zero retains issue date; no weekend/holiday adjustment or legal payment rule inferred")
        case is LateFeeExpression:
            let feeDuration = try nominal(pop()); let feeRate = try nominal(pop()); let feePrincipal = try nominal(pop())
            let fee = try FinancialArithmetic(budget, cancellationToken, moneyMath).lateFee(feePrincipal, feeRate, feeDuration)
            result = fee.value; try record("late fee", [feePrincipal, feeRate, feeDuration], result, fee.assumption)
        case let planning as PlanningSentenceExpression:
            let inputs = try popInputs(planning.arguments.count)
            let evaluated = try FinancialArithmetic(budget, cancellationToken, moneyMath).planningSentence(planning, inputs)
            result = evaluated.value; try record(planning.name, inputs, result, evaluated.assumption)
        case let financial as FinancialPlanExpression:
            let inputs = try popInputs(financial.downPayment == nil ? 3 : 4)
            if financial.kind == "grow" && !inputs[1].isPercentage {
                if financial.compoundingSpecified { throw CalcError.arithmetic("Compounding applies to percentage growth, not a flat unit price") }
                result = try rateMath.forDuration(rateMath.at(inputs[0], inputs[1]), inputs[2])
                try record("priced rate total", inputs, result, RateArithmetic.convention + "; fixed elapsed days are 24 hours; no tiers, taxes or calendar billing inferred")
                break
            }
            let evaluated = try FinancialArithmetic(budget, cancellationToken, moneyMath).plan(financial, inputs)
            result = evaluated.value; try record(financial.kind, inputs, result, evaluated.assumption)
            if let schedule = evaluated.schedule, !schedule.isEmpty { amendLastStep { $0.schedule = schedule } }
        case let literal as LiteralExpression: result = SheetValue(literal.value)
        case let currency as CurrencyAttachExpression:
            let currencyMagnitude = try real(pop())
            result = currencyMagnitude.kind == .earnings ? try earningsMath.currency(currencyMagnitude, currency.currency, moneyMath, true) : .money(try moneyMath.attach(currencyMagnitude, currency.currency))
            try record("currency", [currencyMagnitude], result, "Explicit currency identity; exact magnitude retained; displayed amounts use pinned minor-unit digits")
        case let time as TimeLiteralExpression: result = try .clock(time.time)
        case let holiday as AnnualHolidayExpression: result = .holidayList(try HolidaySet([HolidayDate(holiday.month, holiday.day)]))
        case let resistor as ResistorLiteralExpression:
            result = .resistor(try electricalMath.decode(resistor.bands)); try record("resistor marking", [], result)
        case let list as ListExpression:
            let items = try popInputs(list.items.count)
            let holidayDates = !items.isEmpty && items.allSatisfy { $0.kind == .date || $0.kind == .holidayList }
            if items.contains(where: { $0.kind == .list }) { result = .matrix(try SheetMatrix(try items.map { try $0.list })) }
            else if holidayDates {
                result = .holidayList(try HolidaySet(try items.flatMap { item -> [HolidayDate] in
                    if case .date(let d) = item { return [HolidayDate(d.month, d.day, d.year)] }
                    return try item.holidays.dates
                }))
            } else { result = .list(try SheetList(items)) }
            let assumption: String
            if case .matrix(let m) = result { assumption = "\(m.rowCount)x\(m.columnCount) immutable rectangular matrix; " + MatrixArithmetic.convention }
            else if holidayDates { assumption = "Annual month/day entries recur; full dates apply once; maximum 256 dates" }
            else { assumption = String(items.count) + " numeric/monetary values; flat immutable list; preview may abbreviate; copy includes every formatted value" }
            try record(result.kind == .matrix ? "matrix" : holidayDates ? "holiday dates" : "list", Array(items.prefix(8)), result, assumption)
        case is WorkdayPeriodExpression:
            let workingCount = try nominal(pop()); let workdays = try WorkdayPeriod(WorkdayArithmetic.count(workingCount), readWorkdayCalendar())
            result = .workdayPeriod(workdays)
            let calendar = workdays.calendar
            try record("working days", [workingCount], result, calendar.scope + "; rules " + WorkdayCalendar.ruleVersion + "; current-rule projection " + String(calendar.firstYear) + "–" + String(calendar.lastYear) +
                       "; calendar captured here; " + String(calendar.customHolidays.dates.count) + " custom dates")
        case is WorkdayCountExpression:
            let workTo = try nominal(pop()); let workFrom = try nominal(pop()); let workCalendar = try readWorkdayCalendar()
            result = try workdayMath.between(try workFrom.date, try workTo.date, workCalendar)
            try record("count working days", [workFrom, workTo], result, workCalendar.scope + "; rules " + WorkdayCalendar.ruleVersion + "; current-rule projection " + String(workCalendar.firstYear) + "–" +
                       String(workCalendar.lastYear) + "; both endpoints included; reversed range negated; weekends Saturday/Sunday; " + String(workCalendar.customHolidays.dates.count) + " custom dates")
        case let calendarEvent as CalendarEventExpression:
            result = try countdowns.event(calendarEvent)
            try record("calendar occurrence", [], result, "Upcoming Gregorian date, inclusive of today; weekdays inclusive; no regional holiday observance adjustment")
        case is CountdownExpression:
            let endpoint = try nominal(pop()); let (value, target, expired) = try countdowns.until(endpoint); result = value
            try record("countdown", [endpoint], result, (expired ? "Expired; clamped to zero. " : "Elapsed time remaining. ") + "Target " + target.description + "; " + target.zoneId + "; " + target.ruleVersion + "; day = 24 elapsed hours")
        case let countdownZone as CountdownZoneExpression:
            let deadline = try nominal(pop()); result = try timestamps.zone(deadline, countdownZone.zone, deadline.kind == .zonedMoment, countdownZone.ambiguity)
            try record("countdown target zone", [deadline], result, try result.moment.zoneId + "; " + result.moment.ruleVersion)
        case is NowExpression: result = try timestamps.now(); try record("current instant", [], result, "One host snapshot shared by all lines and nested calls")
        case is TimestampJoinExpression:
            let clock = try nominal(pop()); let calendar = try nominal(pop())
            result = calendar.kind == .date && clock.kind == .time ? try TimestampArithmetic.join(calendar, clock) : try rateMath.at(calendar, clock)
            try record(result.kind == .localTimestamp ? "local timestamp" : "at rate", [calendar, clock], result, result.kind == .localTimestamp ? "Gregorian date and unzoned clock reading" : RateArithmetic.convention)
        case let zone as ZoneExpression:
            let local = try nominal(pop()); result = try timestamps.zone(local, zone.zone, zone.conversion, zone.ambiguity)
            try record(zone.conversion ? "convert zone" : "resolve zone", [local], result,
                       try result.moment.zoneId + "; " + result.moment.ruleVersion + "; skipped times rejected; ambiguity " + (zone.ambiguity.isEmpty ? "rejected" : zone.ambiguity))
        case let choice as UnitOrZoneExpression:
            let input = try real(pop())
            if input.kind == .number { result = .number(choice.conversion ? try quantities.convert(try input.number, choice.unit) : try quantities.attach(try input.number, choice.unit)) }
            else { result = try timestamps.zone(input, choice.zone, choice.conversion, "") }
            try record(choice.conversion ? "convert" : "attach", [input], result, result.kind == .zonedMoment ? try result.moment.zoneId + "; " + result.moment.ruleVersion : "Exact unit definitions")
        case let unix as UnixExpression:
            let unixOperand = try nominal(pop()); result = try TimestampArithmetic.unix(unixOperand, unix.export)
            try record(unix.export ? "Unix seconds" : "Unix timestamp", [unixOperand], result, "Exact seconds since 1970-01-01T00:00:00Z; no leap seconds; 100 ns precision")
        case is TimeRangeExpression:
            let end = try nominal(pop()); let start = try nominal(pop()); result = try TimeArithmetic.range(start, end)
            try record("clock interval", [start, end], result, "Unzoned wall-clock interval; an earlier same-day endpoint rolls over once; equal endpoints mean zero")
        case let date as DateLiteralExpression: result = .date(date.date)
        case let anchor as DateAnchorExpression:
            contextReads.dependencies.insert(.date)
            result = try dates.anchor(anchor); try record("calendar anchor", [], result, "Host date snapshot; next/last weekdays are strictly future/past")
        case let period as CalendarPeriodExpression:
            let count = try nominal(pop()); result = try DateArithmetic.monthPeriod(count, period.monthsPerUnit)
            try record("calendar months", [count], result, "Calendar months are not fixed elapsed seconds")
        case let interval as DateIntervalExpression:
            let to = try nominal(pop()); let from = try nominal(pop()); result = try DateArithmetic.interval(interval.kind, from, to)
            try record(interval.kind, [from, to], result, interval.kind == "age" ? "Completed Gregorian anniversaries; February 29 clamps to February 28" : "Signed calendar-day difference; endpoints not both counted")
        case let shift as DateShiftExpression:
            let offset = try nominal(pop()); let origin = try nominal(pop())
            if case .workdayPeriod(let workdays) = offset {
                result = try workdayMath.shift(try origin.date, shift.direction < 0 ? try workdays.with(count: -workdays.count) : workdays)
                try record("relative date", [origin, offset], result, workdays.calendar.scope + "; captured rules " + WorkdayCalendar.ruleVersion + "; origin excluded; zero retains origin; weekends/holidays skipped")
            } else {
                result = try DateArithmetic.shift(origin, offset, shift.direction)
                try record("relative date", [origin, offset], result, "Whole calendar days; months applied before days; month end clamps")
            }
        case let name as NameExpression:
            result = try resolve(name.name)
            var note = name.name
            if case .money(let money) = result, let stamp = money.rateStamp { note += "; cached " + stamp.provider + " rates as of " + stamp.asOf.description }
            try record("reference", [], result, note)
        case let unit as UnitExpressionNode:
            let operand = try real(pop())
            switch operand {
            case .usageCount(let count): result = try rateMath.attach(count, unit.unit, unit.conversion)
            case .money(let money): result = .money(unit.conversion ? try moneyMath.convertUnit(money, unit.unit) : try moneyMath.attachUnit(money, unit.unit))
            default: result = .number(unit.conversion ? try quantities.convert(try operand.number, unit.unit) : try quantities.attach(try operand.number, unit.unit))
            }
            try record(unit.conversion ? "convert unit" : "attach unit", [operand], result,
                       "Exact definitions; dimensions checked; target " + unit.unit.symbol + (unit.unit.fuelForm() != 0 ? "; " + HelperArithmetic.fuelUnits : ""))
        case let scale as ScaleExpression:
            let operand = try nominal(pop())
            switch operand {
            case .complex: result = try complexMath.scale(operand, scale.factor)
            case .usageCount, .usagePrice: result = try rateMath.binary("*", operand, SheetValue(scale.factor))
            case .money(let money): result = .money(try MoneyValue(try quantities.scale(money.magnitude, scale.factor), money.currency, money.rateStamp, money.exactDisplay))
            case .earnings: result = try earningsMath.binary("*", operand, SheetValue(scale.factor))
            default: result = .number(try quantities.scale(try operand.number, scale.factor))
            }
            try record("scale by " + scale.modifier, [operand, SheetValue(scale.factor)], result, "Exact numeric multiplier; percentage type preserved")
        case let unary as UnaryExpression:
            var arg = pop()
            if let integerResult = try integerMath.tryUnary(unary.operation, arg) { result = integerResult; try record(unary.operation, [arg], result, IntegerArithmetic.convention); break }
            arg = try nominal(arg)
            if arg.kind == .prime { throw CalcError.arithmetic(PrimeArithmetic.notNumeric) }
            if arg.kind == .complex { result = try complexMath.unary(unary.operation, arg); try record(unary.operation, [arg], result, ComplexArithmetic.convention); break }
            if arg.kind == .usageCount || arg.kind == .usagePrice { result = try rateMath.unary(unary.operation, arg); try record(unary.operation, [arg], result, RateArithmetic.convention); break }
            if MatrixArithmetic.isCollection(arg) { result = try matrixMath.unary(unary.operation, arg); try record(unary.operation, [arg], result, MatrixArithmetic.convention); break }
            if unary.operation == "!", case .number(let n) = arg, n.isApproximate { throw CalcError.arithmetic("Factorial requires an exact integer") }
            if arg.kind == .earnings { result = try earningsMath.unary(unary.operation, arg); try record(unary.operation, [arg], result); break }
            if case .money(let money) = arg { result = .money(try moneyMath.unary(unary.operation, money)); try record(unary.operation, [arg], result); break }
            if case .workdayPeriod(let workdays) = arg {
                if unary.operation != "+" && unary.operation != "-" { throw CalcError.arithmetic("Unsupported working-day unary operation") }
                result = .workdayPeriod(unary.operation == "-" ? try workdays.with(count: -workdays.count) : workdays)
                try record(unary.operation, [arg], result); break
            }
            if arg.kind == .time { throw CalcError.arithmetic("A clock reading cannot use a unary numeric operator") }
            if arg.kind != .number {
                if unary.operation == "-" { result = try DateArithmetic.negate(arg) }
                else if unary.operation == "+" && arg.kind == .calendarPeriod { result = arg }
                else { throw CalcError.arithmetic("Invalid date/calendar unary operation") }
            } else if unary.operation == "!" { result = SheetValue(try ExpressionEvaluation.factorial(try arg.scalar, cancellationToken)) }
            else { result = .number(try quantities.unary(unary.operation, try arg.number)) }
            try record(unary.operation, [arg], result)
        case let binary as BinaryExpression:
            var right = pop(); var left = pop()
            if left.kind == .prime || right.kind == .prime { throw CalcError.arithmetic(PrimeArithmetic.notNumeric) }
            if try complexMath.applies(binary.operation, left, right) {
                left = try nominal(left); right = try nominal(right); result = try complexMath.binary(binary.operation, left, right)
                try record(binary.operation, [left, right], result, ComplexArithmetic.convention); break
            }
            if left.kind == .network || right.kind == .network {
                guard binary.operation == "/", case .network(let network) = left, network.form == .address else {
                    throw CalcError.arithmetic("Network values do not support numeric arithmetic; use explicit network functions")
                }
                result = try networkMath.attach(left, right); try record("CIDR subnet", [left, right], result, NetworkArithmetic.convention); break
            }
            if [.usageCount, .usagePrice].contains(left.kind) || [.usageCount, .usagePrice].contains(right.kind) {
                result = try rateMath.binary(binary.operation, left, right); try record(binary.operation, [left, right], result, RateArithmetic.convention); break
            }
            if binary.operation == "/", case .number(let l) = left, l.unit?.dimension == RateArithmetic.data, case .number(let r) = right, r.unit?.dimension == TimeArithmetic.timeDimension {
                result = try rateMath.throughput(left, right)
                try record("throughput", [left, right], result, RateArithmetic.convention + "; two-decimal rate presentation retains exact magnitude"); break
            }
            if let integerResult = try integerMath.tryBinary(binary.operation, left, right) { result = integerResult; try record(binary.operation, [left, right], result, IntegerArithmetic.convention); break }
            right = try nominal(right); left = try nominal(left)
            if binary.operation == "||" { result = try electricalMath.parallel([left, right]); try record("parallel", [left, right], result, ElectricalArithmetic.parallelAssumption); break }
            if MatrixArithmetic.isCollection(left) || MatrixArithmetic.isCollection(right) {
                result = try matrixMath.binary(binary.operation, left, right); try record(binary.operation, [left, right], result, MatrixArithmetic.convention); break
            }
            let relative = !left.isPercentage && right.isPercentage && (binary.operation == "+" || binary.operation == "-")
            if left.kind == .earnings || right.kind == .earnings { result = try earningsMath.binary(binary.operation, left, right) }
            else if left.kind == .money || right.kind == .money { result = try moneyMath.binary(binary.operation, left, right) }
            else if left.kind == .workdayPeriod || right.kind == .workdayPeriod { result = try workdayMath.binary(binary.operation, left, right) }
            else if TimestampArithmetic.isTimestamp(left) || TimestampArithmetic.isTimestamp(right) { result = try TimestampArithmetic.binary(binary.operation, left, right) }
            else if left.kind == .time || right.kind == .time { result = try TimeArithmetic.binary(binary.operation, left, right) }
            else if case .number(let l) = left, case .number(let r) = right { result = .number(try quantities.binary(binary.operation, l, r)) }
            else { result = try dates.binary(binary.operation, left, right) }
            if ["*", "/", "of"].contains(binary.operation) { result = try ElectricalArithmetic.preferElectricalUnit(left, right, result) }
            let assumption: String?
            if left.kind == .earnings || right.kind == .earnings { assumption = earningsMath.assumption ?? "Typed earnings arithmetic; calendar and elapsed durations remain distinct; daily earnings use an 8-hour working day" }
            else if left.kind == .money || right.kind == .money { assumption = moneyMath.provenance ?? "Exact monetary arithmetic; display rounding does not replace source amounts" }
            else if left.kind == .workdayPeriod || right.kind == .workdayPeriod {
                let workdays = left.kind == .workdayPeriod ? try left.workdays : try right.workdays
                assumption = workdays.calendar.scope + "; captured rules " + WorkdayCalendar.ruleVersion + "; shift excludes origin, zero retains origin; weekends/holidays skipped; not elapsed time"
            } else { assumption = relative ? "Percentage change relative to the left operand" : nil }
            try record(binary.operation, [left, right], result, assumption)
        case let call as CallExpression:
            var args = [SheetValue](repeating: .number(NumericValue()), count: call.arguments.count)
            var i = args.count - 1
            while i >= 0 { args[i] = pop(); i -= 1 }
            let name = call.name
            if RateArithmetic.isFunction(name) {
                result = try rateMath.function(name, try args.map(nominal))
                let assumption: String; if case .uptimeBudget(let b) = result { assumption = try b.details } else { assumption = RateArithmetic.convention }
                try record(name, args, result, assumption); break
            }
            if DeveloperArithmetic.isFunction(name) { result = try developerMath.function(name, args); try record(name, args, result, DeveloperArithmetic.convention); break }
            if TextArithmetic.isFunction(name) {
                let textResult = try textMath.function(name, args); result = textResult.value
                try record(name, args, result, TextArithmetic.convention)
                amendLastStep { $0.textTransform = textResult.evidence }; break
            }
            if NetworkArithmetic.isFunction(name) { result = try networkMath.function(name, args); try record(name, args, result, NetworkArithmetic.convention); break }
            if IntegerArithmetic.isFunction(name) { result = try integerMath.function(name, args); try record(name, args, result, IntegerArithmetic.convention); break }
            if HelperArithmetic.isFunction(name) {
                args = try args.map(nominal); let computed = try helperMath.function(name, args); result = computed.value
                try record(computed.operation, args, result, computed.assumption); break
            }
            if TableArithmetic.isFunction(name) { let selected = try TableArithmetic.function(name, args); result = selected.value; try record(name, args, result, selected.assumption); break }
            if EquationSyntax.function(name) {
                result = try formulaMath.solutionFunction(name, try args.map(nominal))
                try record(name, args, result, "Root taken from the retained solve result; order ascending"); break
            }
            if FormulaFunctions.isSheetFunction(name) {
                args = try args.map(nominal); result = try formulaMath.sheetFunction(name, args)
                try record(name, args, result, FormulaFunctions.convention + "; 12 significant digits"); break
            }
            if name.equalsIgnoreCase("engineering") {
                result = try practicalMath.engineering(try args.map(nominal)); try record(name, args, result, PracticalArithmetic.engineeringAssumption); break
            }
            if name.equalsIgnoreCase("weightedMean") {
                try PracticalArithmetic.validateArity(name, args.count)
                result = try practicalMath.grades(try args[0].list.values.map(nominal), try args[1].list.values.map(nominal))
                try record(name, args, result, "Weighted mean sum(score*weight) / sum(weight); no grading range or pass threshold inferred; exact represented magnitudes, four-decimal display"); break
            }
            if ElectricalArithmetic.isFunction(name) {
                try ElectricalArithmetic.validateArity(name, args.count)
                if name.equalsIgnoreCase("parallel") { result = try electricalMath.parallel(try args.map(nominal)); try record(name, args, result, ElectricalArithmetic.parallelAssumption) }
                else { result = .resistor(try electricalMath.encode(args, name.equalsIgnoreCase("resistorColors"))); try record(name, args, result) }
                break
            }
            if FunctionLibrary.isBuiltin(name) { args = try args.map(nominal) }
            if try complexMath.applies(name, args) { result = try complexMath.function(name, args); try record(name, args, result, ComplexArithmetic.convention); break }
            if PrimeArithmetic.isFunction(name) { let primed = try primeMath.function(name, args); result = primed.value; try record(name, args, result, primed.evidence); break }
            if MatrixArithmetic.isFunction(name) { result = try matrixMath.function(name, args); try record(name, args, result, MatrixArithmetic.convention); break }
            if RomanianTaxArithmetic.isFunction(name) {
                let evaluated = try RomanianTaxArithmetic(budget, cancellationToken).function(name, args)
                result = evaluated.value; try record(name, args, result, evaluated.assumption)
                amendLastStep { $0.romanianTax = evaluated.evidence }; break
            }
            if StatisticsArithmetic.isFunction(name) {
                let evaluated = try StatisticsArithmetic(math, budget, cancellationToken, moneyMath).function(name, args)
                result = evaluated.value; try record(name, args, result, evaluated.assumption); break
            }
            if FinancialArithmetic.isFunction(name) {
                let evaluated = try FinancialArithmetic(budget, cancellationToken, moneyMath).function(name, args)
                result = evaluated.value; try record(name, args, result, evaluated.assumption)
                if let irr = evaluated.irr { amendLastStep { $0.irr = irr } }
                if let growth = evaluated.growth { amendLastStep { $0.growth = growth } }
                break
            }
            if name.equalsIgnoreCase("abs") && args.count == 1, case .earnings(let rate) = args[0] {
                let amount = rate.amount.kind == .money ? try moneyMath.function("abs", [rate.amount]) : SheetValue.number(try quantities.function("abs", [try rate.amount.number]))
                result = .earnings(try EarningsValue(amount, rate.period))
            } else if FunctionLibrary.isBuiltin(name) {
                result = args.contains(where: { $0.kind == .money }) ? try moneyMath.function(name, args) : .number(try quantities.function(name, try args.map { try $0.number }))
            } else { throw CalcError.format("User functions are dispatched outside the primitive operation frame") }
            try record(name, args, result, moneyMath.provenance ?? describeFunction?(name))
        case let total as AggregateExpression:
            let scalarSources = try aggregate.filter { !ExpressionEvaluation.excludedFromAggregate($0) }.map(nominal)
            if scalarSources.contains(where: { $0.kind == .usageCount || $0.kind == .usagePrice }) { result = try rateMath.aggregate(scalarSources, total.average) }
            else if scalarSources.contains(where: { $0.kind == .earnings }) { result = try earningsMath.aggregate(scalarSources, total.average) }
            else if scalarSources.contains(where: { $0.kind == .money }) { result = .money(try moneyMath.aggregate(scalarSources, total.average, cancellationToken)) }
            else { result = .number(try quantities.aggregate(try scalarSources.map { try $0.number }, total.average, cancellationToken)) }
            try record(total.average ? "average" : "sum", Array(scalarSources.prefix(8)), result,
                       "\(scalarSources.count) source lines; aggregate result, list/matrix data, solve, complex, prime, table and figure lines excluded" + (moneyMath.provenance.map { "; " + $0 } ?? ""))
        case let rounding as RoundingExpression:
            let precision = try nominal(pop()); let operand = try nominal(pop())
            switch operand {
            case .complex: result = try complexMath.round(rounding.kind, operand, try precision.number)
            case .usageCount, .usagePrice: result = try rateMath.round(rounding.kind, operand, precision)
            case _ where MatrixArithmetic.isCollection(operand): result = try matrixMath.round(rounding.kind, operand, precision)
            case .earnings: result = try earningsMath.round(rounding.kind, operand, precision)
            case .money(let money): result = .money(try moneyMath.round(rounding.kind, money, precision, cancellationToken))
            default: result = .number(try quantities.round(rounding.kind, try operand.number, try precision.number, cancellationToken))
            }
            let operation: String
            switch rounding.kind { case .decimalPlaces: operation = "round to decimal places"; case .increment: operation = "round to increment"; case .significantFigures: operation = "round to significant figures" }
            try record(operation, [operand, precision], result, "Exact arithmetic; halfway cases round away from zero" + (moneyMath.provenance.map { "; " + $0 } ?? "") +
                       (operand.isPercentage && rounding.kind != .increment ? "; precision applies to percentage points" : ""))
        default: throw CalcError.format("Unknown expression")
        }
        return result
    }
    func convertCurrency(_ currency: CurrencyConvertExpression) throws -> SheetValue {
        let source: SheetValue
        var converter = moneyMath
        if currency.date != nil {
            let date = try pop().date
            contextReads.dependencies.insert(.date)
            if let today = context.today, date > today { throw CalcError.arithmetic("Future historical currency rates are unavailable") }
            let datedContext = context.with { $0.currencyDate = date }
            let evaluated = try ExpressionEvaluation.evaluate(currency.operand, resolve, aggregate, cancellationToken, userFunction, budget, describeFunction, datedContext, contextReads)
            source = evaluated.value
            for step in evaluated.steps { if steps.count >= 62 { break }; steps.append(step) }
            converter = MoneyArithmetic(math, datedContext, contextReads)
        } else { source = try nominal(pop()) }
        if source.kind == .earnings && currency.unit != nil { throw CalcError.arithmetic("Convert earnings periods with in hourly/daily/monthly/yearly separately from currency conversion") }
        let result: SheetValue
        switch source {
        case .usagePrice(let price): result = .usagePrice(try UsagePriceValue(try converter.convert(price.amount, currency.currency, currency.unit), price.perCount, price.kind))
        case .earnings: result = try earningsMath.currency(source, currency.currency, converter)
        default: result = .money(try converter.convert(try source.money, currency.currency, currency.unit))
        }
        try record("convert currency", [source], result, converter.provenance ?? "Identity currency conversion; no rate lookup")
        return result
    }
    func run() throws -> (value: SheetValue, steps: [CalculationStep]) {
        var stack: [(node: Expression, ready: Bool)] = [(expression, false)]
        while let frame = stack.popLast() {
            try budget.step(cancellationToken)
            if !frame.ready {
                stack.append((frame.node, true))
                let children: [Expression]
                if let currency = frame.node as? CurrencyConvertExpression, let currencyDate = currency.date { children = [currencyDate] } else { children = frame.node.children }
                for child in children.reversed() { stack.append((child, false)) }
                continue
            }
            let result: SheetValue
            if let call = frame.node as? CallExpression, !FunctionLibrary.isBuiltin(call.name) {
                var args = [SheetValue](repeating: .number(NumericValue()), count: call.arguments.count)
                var i = args.count - 1
                while i >= 0 { args[i] = pop(); i -= 1 }
                let callContext = context.uuids == nil ? context : context.with { $0.uuidPath = context.uuidPath + "/" + String(call.site) + ":" + call.name.netUpper }
                guard let userFunction else { throw CalcError.format("Unknown function: \(call.name)") }
                let invoked = try userFunction(call.name, args, callContext)
                result = invoked.value
                for step in invoked.steps { if steps.count >= 62 { break }; steps.append(step) }
                try record(call.name, args, result, moneyMath.provenance ?? describeFunction?(call.name))
            } else if let currency = frame.node as? CurrencyConvertExpression { result = try convertCurrency(currency) }
            else { result = try evaluateNode(frame.node) }
            _ = try result.display // Bound presentation before publishing a successful result.
            values.append(result)
        }
        let answer = pop()
        if steps.count == 63 { steps.append(CalculationStep("result", [], ExpressionEvaluation.preview(try answer.display), "Explanation limited to 63 operations")) }
        if steps.isEmpty { steps.append(CalculationStep("literal", [], ExpressionEvaluation.preview(try answer.display))) }
        return (answer, steps)
    }
}

/// C# DiceUnrolledException: a dice line that has not been rolled yet.
struct DiceUnrolledError: Error { let preview: String; let steps: [CalculationStep] }
