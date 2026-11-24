import Foundation

/// Typed earnings rates: calendar (month/year) and working-time (hour/workday) periods stay distinct until an
/// explicit conversion. Converting between the two families enumerates the context year's working days.
final class EarningsArithmetic {
    private let math: ExactArithmetic, money: MoneyArithmetic, workdays: WorkdayArithmetic
    private let context: EvaluationContext, reads: ContextReads, token: CancellationToken
    private let quantities: QuantityArithmetic
    private(set) var assumption: String?
    init(_ math: ExactArithmetic, _ money: MoneyArithmetic, _ workdays: WorkdayArithmetic, _ context: EvaluationContext, _ reads: ContextReads, _ token: CancellationToken) {
        self.math = math; self.money = money; self.workdays = workdays; self.context = context; self.reads = reads; self.token = token
        quantities = QuantityArithmetic(math)
    }
    private static func per(_ unit: String) throws -> UnitExpression { try UnitExpression.single(UnitCatalog.byId(unit)).power(Rational(-1)) }
    private func scaleAmount(_ amount: SheetValue, _ factor: Rational) throws -> SheetValue {
        if amount.kind == .money {
            let value = try amount.money
            return .money(try MoneyValue(try quantities.scale(value.magnitude, factor), value.currency, value.rateStamp, value.exactDisplay))
        }
        return .number(try quantities.scale(try amount.number, factor).with { $0.displayDecimalPlaces = 4 })
    }
    private func amountBinary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue {
        left.kind == .money || right.kind == .money ? try money.binary(operation, left, right) : .number(try quantities.binary(operation, try left.number, try right.number))
    }
    /// An earnings value, or an hourly/daily physical rate (`100 EUR/h`) read as one.
    func read(_ value: SheetValue) throws -> EarningsValue {
        if case .earnings(let rate) = value { return rate }
        let numeric = value.kind == .money ? try value.money.magnitude : try value.number
        let period: EarningsPeriod
        if let unit = numeric.unit, unit == (try EarningsArithmetic.per("h")) { period = .hour }
        else if let unit = numeric.unit, unit == (try EarningsArithmetic.per("day")) { period = .day }
        else { throw CalcError.arithmetic("Expected an hourly/daily rate or a calendar earnings rate") }
        let displayed = try quantities.displayMagnitude(numeric)
        let number = numeric.with { $0.exact = displayed; $0.unit = nil; $0.quantityKind = ""; $0.useCompoundDuration = false; $0.useDaysInDuration = false }
        if value.kind == .money {
            let source = try value.money
            return try EarningsValue(.money(try MoneyValue(number, source.currency, source.rateStamp, source.exactDisplay)), period)
        }
        return try EarningsValue(.number(number), period)
    }
    private func factor(_ from: EarningsPeriod, _ to: EarningsPeriod) throws -> Rational {
        if assumption == nil { assumption = "Earnings periods; 12 equal monthly amounts per year; 8 hours per working day; no leave, overtime, taxes or billable-utilization adjustment" }
        if from == to { return .one }
        let fromCalendar = from == .month || from == .year
        let toCalendar = to == .month || to == .year
        if fromCalendar && toCalendar { return from == .month ? Rational(12) : try Rational(1, 12) }
        if !fromCalendar && !toCalendar { return from == .hour ? Rational(8) : try Rational(1, 8) }
        reads.dependencies.formUnion([.date, .workdayCalendar])
        let year = try context.requireToday().year
        let calendar = try WorkdayCalendar(context.workdayRegion, context.customHolidays)
        let days = try workdays.between(DateOnly(year, 1, 1)!, DateOnly(year, 12, 31)!, calendar).scalar
        if days.sign <= 0 { throw CalcError.arithmetic("No working days available in the selected earnings year") }
        assumption! += "; context year " + String(year) + "; " + days.description + " working days; " + calendar.scope + "; rules " + WorkdayCalendar.ruleVersion +
            "; custom holidays included; current-rule projection; no days-per-month approximation"
        func annualUnits(_ period: EarningsPeriod) throws -> Rational {
            switch period { case .hour: return try days * Rational(8); case .day: return days; case .month: return Rational(12); case .year: return .one }
        }
        return try annualUnits(from) / annualUnits(to)
    }
    func convert(_ value: SheetValue, _ target: EarningsPeriod) throws -> SheetValue {
        let source = try read(value)
        return .earnings(try EarningsValue(try scaleAmount(source.amount, try factor(source.period, target)), target))
    }
    func currency(_ source: SheetValue, _ currency: String, _ converter: MoneyArithmetic, _ attach: Bool = false) throws -> SheetValue {
        let rate = try source.earnings; let amount = rate.amount
        let converted = attach ? try converter.attach(amount, currency) : try converter.convert(try amount.money, currency)
        return .earnings(try EarningsValue(.money(converted), rate.period))
    }
    func unary(_ operation: String, _ value: SheetValue) throws -> SheetValue {
        let rate = try value.earnings
        if operation != "+" && operation != "-" { throw CalcError.arithmetic("Unsupported earnings unary operation") }
        return .earnings(try EarningsValue(try scaleAmount(rate.amount, Rational(operation == "-" ? -1 : 1)), rate.period))
    }
    func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue {
        let leftRate = left.kind == .earnings
        let rate = try (leftRate ? left : right).earnings; let other = leftRate ? right : left
        if other.kind == .earnings {
            try EarningsArithmetic.requireSameFamily(rate.period, try other.earnings.period)
            let converted = try convert(other, rate.period).earnings.amount
            if operation == "+" || operation == "-" {
                return .earnings(try EarningsValue(try amountBinary(operation, leftRate ? rate.amount : converted, leftRate ? converted : rate.amount), rate.period))
            }
            if operation == "/" { return try amountBinary("/", leftRate ? rate.amount : converted, leftRate ? converted : rate.amount) }
            throw CalcError.arithmetic("Earnings rates cannot be multiplied")
        }
        if case .calendarPeriod(let period) = other, operation == "*" {
            if rate.period != .month && rate.period != .year || period.days != 0 {
                throw CalcError.arithmetic("Calendar earnings multiplication requires whole calendar months and a monthly/yearly rate")
            }
            return try scaleAmount(rate.amount, try Rational(period.months, rate.period == .year ? 12 : 1))
        }
        guard case .number(let number) = other else { throw CalcError.arithmetic("Earnings arithmetic requires compatible rates, scalar scaling or a matching duration") }
        if let unit = number.unit {
            if operation != "*" || unit.dimension != TimeArithmetic.timeDimension || rate.period != .hour && rate.period != .day {
                throw CalcError.arithmetic("Use calendar periods for monthly/yearly earnings; hours/days require a worked duration")
            }
            // Seconds per worked hour or per 8-hour working day.
            let divisor = rate.period == .hour ? 3600 : 28800
            let scaled = try math.scale(number.exact, try Rational(1, divisor))
            let duration = number.with { $0.exact = scaled; $0.unit = nil; $0.quantityKind = ""; $0.useCompoundDuration = false; $0.useDaysInDuration = false }
            return try amountBinary("*", rate.amount, .number(duration))
        }
        if (operation == "+" || operation == "-") && leftRate && number.isPercentage {
            return .earnings(try EarningsValue(try amountBinary(operation, rate.amount, other), rate.period))
        }
        if operation == "*" || operation == "of" || operation == "/" && leftRate {
            return .earnings(try EarningsValue(try amountBinary(operation, rate.amount, other), rate.period))
        }
        throw CalcError.arithmetic("Do not add bare amounts to earnings rates or divide by a rate")
    }
    func round(_ kind: RoundingKind, _ value: SheetValue, _ precision: SheetValue) throws -> SheetValue {
        let rate = try value.earnings
        var precision = precision
        if case .earnings(let quantum) = precision {
            try EarningsArithmetic.requireSameFamily(rate.period, quantum.period)
            precision = try convert(precision, rate.period).earnings.amount
        }
        let rounded: SheetValue = rate.amount.kind == .money ? .money(try money.round(kind, try rate.amount.money, precision, token)) :
            .number(try quantities.round(kind, try rate.amount.number, try precision.number, token))
        return .earnings(try EarningsValue(rounded, rate.period))
    }
    func aggregate(_ values: [SheetValue], _ average: Bool) throws -> SheetValue {
        if values.isEmpty || values.contains(where: { $0.kind != .earnings }) { throw CalcError.arithmetic("Aggregate earnings rates separately from amounts and other quantities") }
        let period = try values[0].earnings.period; var amounts: [SheetValue] = []
        for value in values {
            try token.throwIfCancellationRequested()
            try EarningsArithmetic.requireSameFamily(period, try value.earnings.period)
            amounts.append(try convert(value, period).earnings.amount)
        }
        let result: SheetValue = amounts.contains(where: { $0.kind == .money }) ? .money(try money.aggregate(amounts, average, token)) :
            .number(try quantities.aggregate(try amounts.map { try $0.number }, average, token))
        return .earnings(try EarningsValue(result, period))
    }
    private static func requireSameFamily(_ first: EarningsPeriod, _ second: EarningsPeriod) throws {
        if (first == .month || first == .year) != (second == .month || second == .year) {
            throw CalcError.arithmetic("Convert calendar and hourly/daily earnings explicitly to one period before combining or aggregating")
        }
    }
}
