import Foundation

enum SheetValueKind: String {
    case number = "Number", date = "Date", calendarPeriod = "CalendarPeriod", time = "Time", localTimestamp = "LocalTimestamp", zonedMoment = "ZonedMoment"
    case workdayPeriod = "WorkdayPeriod", holidayList = "HolidayList", money = "Money", list = "List", earnings = "Earnings", matrix = "Matrix"
    case resistor = "Resistor", engineering = "Engineering", integer = "Integer", network = "Network", text = "Text", colour = "Colour"
    case permission = "Permission", aspect = "Aspect", unicode = "Unicode", usageCount = "UsageCount", usagePrice = "UsagePrice", uptimeBudget = "UptimeBudget"
    case equation = "Equation", complex = "Complex", prime = "Prime", practical = "Practical", plot = "Plot", chart = "Chart", table = "Table"
}

/// Typed sheet result (C# SheetValue). Dates and calendar periods cannot silently become numeric magnitudes.
/// The C# constructors that validate (ClockTime, CalendarPeriod, ZonedMoment, WorkdayPeriod) map to the
/// throwing factories `.clock`, `.period` and the validating initialisers of those types.
enum SheetValue: Hashable, CustomStringConvertible {
    case number(NumericValue)
    case date(DateOnly)
    case calendarPeriod(CalendarPeriod)
    case time(ClockTime)
    case localTimestamp(LocalTimestamp)
    case zonedMoment(ZonedMoment)
    case workdayPeriod(WorkdayPeriod)
    case holidayList(HolidaySet)
    case money(MoneyValue)
    case list(SheetList)
    case earnings(EarningsValue)
    case matrix(SheetMatrix)
    case resistor(ResistorValue)
    case engineering(EngineeringValue)
    case integer(IntegerValue)
    case network(NetworkValue)
    case text(TextValue)
    case colour(ColourValue)
    case permission(PermissionValue)
    case aspect(AspectValue)
    case unicode(UnicodeValue)
    case usageCount(UsageCountValue)
    case usagePrice(UsagePriceValue)
    case uptimeBudget(UptimeBudgetValue)
    case equation(EquationValue)
    case complex(ComplexValue)
    case prime(PrimeValue)
    case practical(PracticalValue)
    case plot(PlotValue)
    case chart(ChartValue)
    case table(TableValue)

    init(_ value: NumericValue) { self = .number(value) }
    init(_ value: Rational) { self = .number(NumericValue(value)) }
    /// `new SheetValue(CalendarPeriod)`: checks the period's limits.
    static func period(_ value: CalendarPeriod) throws -> SheetValue { .calendarPeriod(try value.checked()) }
    /// `new SheetValue(ClockTime)`: checks the day offset.
    static func clock(_ value: ClockTime) throws -> SheetValue { .time(try value.checked()) }

    var kind: SheetValueKind {
        switch self {
        case .number: return .number
        case .date: return .date
        case .calendarPeriod: return .calendarPeriod
        case .time: return .time
        case .localTimestamp: return .localTimestamp
        case .zonedMoment: return .zonedMoment
        case .workdayPeriod: return .workdayPeriod
        case .holidayList: return .holidayList
        case .money: return .money
        case .list: return .list
        case .earnings: return .earnings
        case .matrix: return .matrix
        case .resistor: return .resistor
        case .engineering: return .engineering
        case .integer: return .integer
        case .network: return .network
        case .text: return .text
        case .colour: return .colour
        case .permission: return .permission
        case .aspect: return .aspect
        case .unicode: return .unicode
        case .usageCount: return .usageCount
        case .usagePrice: return .usagePrice
        case .uptimeBudget: return .uptimeBudget
        case .equation: return .equation
        case .complex: return .complex
        case .prime: return .prime
        case .practical: return .practical
        case .plot: return .plot
        case .chart: return .chart
        case .table: return .table
        }
    }

    // Typed accessors: they throw C#'s ArithmeticException when the kind differs.
    var number: NumericValue { get throws { if case .number(let v) = self { return v }; throw CalcError.arithmetic("Expected a numeric value") } }
    var date: DateOnly { get throws { if case .date(let v) = self { return v }; throw CalcError.arithmetic("Expected a date") } }
    var period: CalendarPeriod { get throws { if case .calendarPeriod(let v) = self { return v }; throw CalcError.arithmetic("Expected a calendar period") } }
    var time: ClockTime { get throws { if case .time(let v) = self { return v }; throw CalcError.arithmetic("Expected a clock reading") } }
    var timestamp: LocalTimestamp { get throws { if case .localTimestamp(let v) = self { return v }; throw CalcError.arithmetic("Expected a local timestamp") } }
    var moment: ZonedMoment { get throws { if case .zonedMoment(let v) = self { return v }; throw CalcError.arithmetic("Expected a zoned timestamp") } }
    var workdays: WorkdayPeriod { get throws { if case .workdayPeriod(let v) = self { return v }; throw CalcError.arithmetic("Expected working days") } }
    var holidays: HolidaySet { get throws { if case .holidayList(let v) = self { return v }; throw CalcError.arithmetic("Expected a holiday date list") } }
    var money: MoneyValue { get throws { if case .money(let v) = self { return v }; throw CalcError.arithmetic("Expected a monetary value") } }
    var list: SheetList { get throws { if case .list(let v) = self { return v }; throw CalcError.arithmetic("Expected a numeric list") } }
    var earnings: EarningsValue { get throws { if case .earnings(let v) = self { return v }; throw CalcError.arithmetic("Expected an earnings rate") } }
    var matrix: SheetMatrix { get throws { if case .matrix(let v) = self { return v }; throw CalcError.arithmetic("Expected a matrix") } }
    var resistor: ResistorValue { get throws { if case .resistor(let v) = self { return v }; throw CalcError.arithmetic("Expected a resistor marking") } }
    var engineering: EngineeringValue { get throws { if case .engineering(let v) = self { return v }; throw CalcError.arithmetic("Expected engineering notation") } }
    var integer: IntegerValue { get throws { if case .integer(let v) = self { return v }; throw CalcError.arithmetic("Expected an integer") } }
    var network: NetworkValue { get throws { if case .network(let v) = self { return v }; throw CalcError.arithmetic("Expected a network value") } }
    var text: TextValue { get throws { if case .text(let v) = self { return v }; throw CalcError.arithmetic("Expected text") } }
    var colour: ColourValue { get throws { if case .colour(let v) = self { return v }; throw CalcError.arithmetic("Expected colour") } }
    var permission: PermissionValue { get throws { if case .permission(let v) = self { return v }; throw CalcError.arithmetic("Expected permission") } }
    var aspect: AspectValue { get throws { if case .aspect(let v) = self { return v }; throw CalcError.arithmetic("Expected aspect") } }
    var unicode: UnicodeValue { get throws { if case .unicode(let v) = self { return v }; throw CalcError.arithmetic("Expected unicode") } }
    var usageCount: UsageCountValue { get throws { if case .usageCount(let v) = self { return v }; throw CalcError.arithmetic("Expected UsageCount") } }
    var usagePrice: UsagePriceValue { get throws { if case .usagePrice(let v) = self { return v }; throw CalcError.arithmetic("Expected UsagePrice") } }
    var uptimeBudget: UptimeBudgetValue { get throws { if case .uptimeBudget(let v) = self { return v }; throw CalcError.arithmetic("Expected UptimeBudget") } }
    var equation: EquationValue { get throws { if case .equation(let v) = self { return v }; throw CalcError.arithmetic("Expected a solve result") } }
    var complex: ComplexValue { get throws { if case .complex(let v) = self { return v }; throw CalcError.arithmetic("Expected a complex value") } }
    var prime: PrimeValue { get throws { if case .prime(let v) = self { return v }; throw CalcError.arithmetic("Expected a primality or factorization result") } }
    var practical: PracticalValue { get throws { if case .practical(let v) = self { return v }; throw CalcError.arithmetic("Expected a practical helper result") } }
    var plot: PlotValue { get throws { if case .plot(let v) = self { return v }; throw CalcError.arithmetic("Expected a plot") } }
    var chart: ChartValue { get throws { if case .chart(let v) = self { return v }; throw CalcError.arithmetic("Expected a chart") } }
    var table: TableValue { get throws { if case .table(let v) = self { return v }; throw CalcError.arithmetic("Expected a table") } }

    var scalar: Rational { get throws { try number.scalar } }
    var exact: ExactNumber { get throws { try number.exact } }
    var unit: UnitExpression? { get throws { try number.unit } }
    var quantityKind: String { get throws { try number.quantityKind } }
    var isPercentage: Bool { if case .number(let n) = self { return n.isPercentage }; return false }
    var isRational: Bool { if case .number(let n) = self { return n.isRational }; return false }

    var display: String {
        get throws {
            switch self {
            case .plot(let v): return try v.display
            case .chart(let v): return try v.display
            case .table(let v): return try v.display
            case .practical(let v): return try v.display
            case .complex(let v): return try v.display
            case .prime(let v): return try v.display
            case .equation(let v): return try v.display
            case .uptimeBudget(let v): return try v.display
            case .usagePrice(let v): return try v.display
            case .usageCount(let v): return try v.display
            case .unicode(let v): return try v.display
            case .aspect(let v): return try v.display
            case .permission(let v): return try v.display
            case .colour(let v): return try v.display
            case .date(let v): return v.description
            case .calendarPeriod(let v): return v.description
            case .time(let v): return v.description
            case .localTimestamp(let v): return v.description
            case .zonedMoment(let v): return v.description
            case .workdayPeriod(let v): return try v.display
            case .holidayList(let v): return try v.display
            case .money(let v): return try v.display
            case .list(let v): return try v.display
            case .earnings(let v): return try v.display
            case .matrix(let v): return try v.display
            case .resistor(let v): return try v.display
            case .engineering(let v): return try v.display
            case .integer(let v): return try v.display
            case .network(let v): return try v.display
            case .text(let v): return v.display
            case .number(let v): return try v.display
            }
        }
    }
    var copyText: String {
        get throws {
            switch self {
            case .plot(let v): return try v.copyText
            case .chart(let v): return try v.copyText
            case .table(let v): return try v.copyText
            case .practical(let v): return try v.copyText
            case .complex(let v): return try v.copyText
            case .prime(let v): return try v.copyText
            case .number(let v) where v.useConstantNotation: return try v.with { $0.useConstantNotation = false }.display
            case .equation(let v): return try v.copyText
            case .uptimeBudget(let v): return try v.copyText
            case .usagePrice(let v): return try v.copyText
            case .usageCount(let v): return try v.copyText
            case .unicode(let v): return try v.copyText
            case .aspect(let v): return try v.copyText
            case .permission(let v): return try v.copyText
            case .colour(let v): return try v.copyText
            case .text(let v): return v.copyText
            case .network(let v): return try v.copyText
            case .integer(let v): return try v.copyText
            case .list(let v): return try v.copyText
            case .matrix(let v): return try v.copyText
            case .resistor(let v): return try v.copyText
            case .engineering(let v): return try v.copyText
            default: return try display
            }
        }
    }
    var description: String { (try? display) ?? "" }
}

/// One host snapshot shared by every line and nested call in one evaluation (C# EvaluationContext).
struct EvaluationContext {
    var today: DateOnly?
    var now: Instant?
    var timeZones: TimeZoneProvider?
    var localZone: LocalZoneSnapshot?
    var workdayRegion: String?
    var customHolidays: HolidaySet?
    var currencyRates: CurrencyRateBook?
    var uuids: StableUuidContext?
    var uuidLine = 0
    var uuidPath = ""
    var aggregateLabels: [String]?
    var currencyDate: DateOnly?
    var payrollRegion: String?
    /// Currency a sheet shows plain monetary results in. Display-only: values, references and copies keep their own currency.
    var displayCurrency: String?

    init(today: DateOnly? = nil, now: Instant? = nil, timeZones: TimeZoneProvider? = nil, localZone: LocalZoneSnapshot? = nil,
         workdayRegion: String? = nil, customHolidays: HolidaySet? = nil, currencyRates: CurrencyRateBook? = nil) {
        self.today = today; self.now = now; self.timeZones = timeZones; self.localZone = localZone
        self.workdayRegion = workdayRegion; self.customHolidays = customHolidays; self.currencyRates = currencyRates
    }
    func with(_ change: (inout EvaluationContext) -> Void) -> EvaluationContext { var copy = self; change(&copy); return copy }
    func requireToday() throws -> DateOnly {
        guard let today else { throw CalcError.arithmetic("Current date unavailable; supply an evaluation context") }
        return today
    }
    func requireNow() throws -> Instant {
        guard let now else { throw CalcError.arithmetic("Current instant unavailable; supply an evaluation context") }
        return now
    }
    var zones: TimeZoneProvider { timeZones ?? Tzdb.provider }
    func requireLocalZone(_ reads: ContextReads) throws -> LocalZoneSnapshot {
        reads.dependencies.insert(.localZone)
        guard let localZone else { throw CalcError.arithmetic("Local time-zone rules unavailable; supply an evaluation context") }
        return localZone
    }
}

struct ContextDependency: OptionSet, Hashable {
    let rawValue: Int
    static let date = ContextDependency(rawValue: 1), instant = ContextDependency(rawValue: 2), zoneRules = ContextDependency(rawValue: 4)
    static let localZone = ContextDependency(rawValue: 8), secondTick = ContextDependency(rawValue: 16), workdayCalendar = ContextDependency(rawValue: 32)
    static let currencyRates = ContextDependency(rawValue: 64), payrollRegion = ContextDependency(rawValue: 128), uuid = ContextDependency(rawValue: 256)
    static let displayCurrency = ContextDependency(rawValue: 512), dice = ContextDependency(rawValue: 1024)
}

final class ContextReads {
    var dependencies: ContextDependency = []
    var uuidRequests = NetHashSet<UuidRequest>()
    var currencyRequests = NetHashSet<DateOnlyKey>()
}

/// A nullable DateOnly usable as a set element (C# HashSet<DateOnly?>).
struct DateOnlyKey: Hashable { let date: DateOnly? }

final class CalculationStep: Hashable {
    let operation: String
    let operands: [String]
    let result: String
    let assumption: String?
    var schedule: [AmortizationYear]?
    var irr: IrrEvidence?
    var growth: GrowthEvidence?
    var payroll: PayrollEvidence?
    var romanianTax: RomanianTaxEvidence?
    var chemistry: ChemistryEvidence?
    var textTransform: TextTransformEvidence?
    init(_ operation: String, _ operands: [String], _ result: String, _ assumption: String? = nil) {
        self.operation = operation; self.operands = operands; self.result = result; self.assumption = assumption
    }
    /// C# `step with { … }`.
    func copy(_ change: (CalculationStep) -> Void) -> CalculationStep {
        let copy = CalculationStep(operation, operands, result, assumption)
        copy.schedule = schedule; copy.irr = irr; copy.growth = growth; copy.payroll = payroll; copy.romanianTax = romanianTax; copy.chemistry = chemistry; copy.textTransform = textTransform
        change(copy); return copy
    }
    static func == (a: CalculationStep, b: CalculationStep) -> Bool {
        a.operation == b.operation && a.operands == b.operands && a.result == b.result && a.assumption == b.assumption
    }
    func hash(into hasher: inout Hasher) { hasher.combine(operation); hasher.combine(result) }
}

final class LineResult {
    let line: Int
    let value: SheetValue?
    let error: String?
    /// An unrolled dice line's muted range. The line has no value until it is rolled.
    var pending: String?
    var isDeclaration = false
    /// A sheet `sum`/`average` line: the value Share and exports offer as the sheet total.
    var isAggregate = false
    var explanation: [CalculationStep] = []
    var dependencies: [Int] = []
    /// The monetary result converted to the default display currency, when one applies. `value` stays authoritative.
    var shown: SheetValue?
    init(_ line: Int, _ value: SheetValue?, _ error: String?) { self.line = line; self.value = value; self.error = error }
    var display: String { isDeclaration && error == nil ? "" : (value.flatMap { try? $0.display } ?? error ?? pending ?? "") }
    /// C# `result with { Value = null, Error = …, Explanation = [] }`.
    func copy(value: SheetValue?, error: String?, keepExplanation: Bool = true) -> LineResult {
        let copy = LineResult(line, value, error)
        copy.pending = pending; copy.isDeclaration = isDeclaration; copy.isAggregate = isAggregate
        copy.explanation = keepExplanation ? explanation : []; copy.dependencies = dependencies; copy.shown = shown
        return copy
    }
}
