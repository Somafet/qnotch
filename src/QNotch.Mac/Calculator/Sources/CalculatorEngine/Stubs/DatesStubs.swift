// Stub for the dates area: CountdownArithmetic, WorkdayArithmetic/Calendar, WorkdayPeriod, HolidaySet, embedded TZDB.

final class CountdownArithmetic {
    init(_ context: EvaluationContext, _ reads: ContextReads) {}
    func event(_ expression: CalendarEventExpression) throws -> SheetValue { throw notPorted("calendar occurrences") }
    func until(_ endpoint: SheetValue) throws -> (value: SheetValue, target: ZonedMoment, expired: Bool) { throw notPorted("countdowns") }
}
struct HolidayDate: Hashable {
    let month: Int, day: Int, year: Int?
    init(_ month: Int, _ day: Int, _ year: Int? = nil) { self.month = month; self.day = day; self.year = year }
}
final class HolidaySet: IdentityHashable {
    static let empty = try! HolidaySet([])
    let dates: [HolidayDate]
    init(_ dates: [HolidayDate]) throws { self.dates = dates }
    var display: String { get throws { throw notPorted("holiday lists") } }
}
final class WorkdayCalendar {
    static let ruleVersion = "2026-10-31"
    let scope = "", firstYear = 0, lastYear = 0
    let customHolidays = HolidaySet.empty
    init(_ region: String?, _ custom: HolidaySet?) throws { throw notPorted("working days") }
}
final class WorkdayPeriod: IdentityHashable {
    let count: Int, calendar: WorkdayCalendar
    init(_ count: Int, _ calendar: WorkdayCalendar) throws { self.count = count; self.calendar = calendar }
    func with(count: Int) throws -> WorkdayPeriod { try WorkdayPeriod(count, calendar) }
    var display: String { get throws { throw notPorted("working days") } }
}
final class WorkdayArithmetic {
    init(_ budget: ExecutionBudget, _ token: CancellationToken) {}
    static func count(_ value: SheetValue) throws -> Int { throw notPorted("working days") }
    func between(_ from: DateOnly, _ to: DateOnly, _ calendar: WorkdayCalendar) throws -> SheetValue { throw notPorted("working days") }
    func shift(_ origin: DateOnly, _ period: WorkdayPeriod) throws -> SheetValue { throw notPorted("working days") }
    func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue { throw notPorted("working days") }
}
/// The embedded TZDB rules (NodaTime's TZDB 2026f in C#).
enum Tzdb {
    static let provider: TimeZoneProvider = UnportedZones()
    private final class UnportedZones: TimeZoneProvider {
        var versionId: String { ZoneCatalog.manifestVersion }
        func zone(_ id: String) -> ZoneRules? { nil }
    }
}
