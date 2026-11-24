import Foundation

/// An annual (month/day) or exact (year/month/day) custom holiday.
struct HolidayDate: Hashable, CustomStringConvertible {
    let month: Int, day: Int, year: Int?
    init(_ month: Int, _ day: Int, _ year: Int? = nil) { self.month = month; self.day = day; self.year = year }
    func checked() throws -> HolidayDate {
        if let year, year < 1 || year > 9999 { throw CalcError.arithmetic("Invalid holiday date") }
        if month < 1 || month > 12 || day < 1 || day > DateOnly.daysInMonth(year ?? 2000, month) { throw CalcError.arithmetic("Invalid holiday date") }
        return self
    }
    /// "yyyy-MM-dd" for an exact date, "d MMM" (invariant month abbreviation) for an annual one.
    var description: String {
        if let year { return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) }
        return String(day) + " " + ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][month - 1]
    }
}

/// Immutable, bounded annual/exact dates. No OS, network or mutable calendar state.
final class HolidaySet: Hashable, CustomStringConvertible {
    static let maxDates = 256
    static let empty = try! HolidaySet([])
    /// Distinct dates ordered by year (annual dates first), month and day.
    let dates: [HolidayDate]
    let key: String
    init(_ dates: [HolidayDate]) throws {
        var values: [HolidayDate] = []
        for date in dates {
            if values.count >= HolidaySet.maxDates { throw CalcError.arithmetic("Holiday list exceeds 256 dates") }
            values.append(try date.checked())
        }
        var seen = Set<HolidayDate>()
        let distinct = values.filter { seen.insert($0).inserted }
        // The (year ?? 0, month, day) key is unique among distinct dates, so this order is total.
        let sorted = distinct.sorted { ($0.year ?? 0, $0.month, $0.day) < ($1.year ?? 0, $1.month, $1.day) }
        self.dates = sorted
        key = sorted.map(\.description).joined(separator: ",")
    }
    static func == (a: HolidaySet, b: HolidaySet) -> Bool { a.key == b.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    var description: String { "[" + dates.map(\.description).joined(separator: ", ") + "]" }
    var display: String { get throws { description } }
}

struct HolidayOccurrence: Hashable { let date: DateOnly, name: String }

/// Current-rule projections, not a prediction of future legislation or an employment schedule.
final class WorkdayCalendar: Hashable {
    static let ruleVersion = "2026-10-31"
    static let supportedRegions = ["DE", "US", "WEEKDAYS"]
    let region: String
    let customHolidays: HolidaySet
    var scope: String {
        switch region { case "DE": return "Germany nationwide holidays"; case "US": return "US federal Monday-Friday observance"; default: return "Weekdays only; no regional holidays" }
    }
    var firstYear: Int { region == "WEEKDAYS" ? 1 : 2022 }
    var lastYear: Int { region == "WEEKDAYS" ? 9999 : 2099 }

    init(_ region: String?, _ holidays: HolidaySet? = nil) throws {
        self.region = region?.netUpper ?? ""
        if !WorkdayCalendar.supportedRegions.contains(self.region) {
            throw CalcError.arithmetic("Holiday calendar unavailable for " + (self.region.isEmpty ? "unspecified region" : self.region))
        }
        customHolidays = holidays ?? HolidaySet.empty
    }
    func check(_ date: DateOnly) throws {
        if date.year < firstYear || date.year > lastYear {
            throw CalcError.arithmetic(region + " holiday rules cover " + String(firstYear) + "–" + String(lastYear) + " only (current-rule projection)")
        }
    }

    func holidays(_ year: Int) throws -> [HolidayOccurrence] {
        if year < firstYear || year > lastYear { throw CalcError.arithmetic(region + " holiday year unavailable") }
        var values: [HolidayOccurrence] = []
        // Dates here are within 0001…9999 by construction (C# would throw ArgumentOutOfRangeException otherwise).
        func date(_ y: Int, _ m: Int, _ d: Int) -> DateOnly { DateOnly(y, m, d)! }
        func fixed(_ month: Int, _ day: Int, _ name: String, _ originYear: Int? = nil) {
            var value = date(originYear ?? year, month, day)
            if region == "US" { value = value.addingDays(value.dayOfWeek == .saturday ? -1 : value.dayOfWeek == .sunday ? 1 : 0)! }
            if value.year == year { values.append(HolidayOccurrence(date: value, name: name)) }
        }
        func nth(_ month: Int, _ day: DayOfWeek, _ occurrence: Int, _ name: String) {
            let first = date(year, month, 1)
            values.append(HolidayOccurrence(date: first.addingDays((day.rawValue - first.dayOfWeek.rawValue + 7) % 7 + (occurrence - 1) * 7)!, name: name))
        }
        if region == "DE" {
            fixed(1, 1, "New Year"); fixed(5, 1, "Labour Day"); fixed(10, 3, "German Unity")
            fixed(12, 25, "Christmas"); fixed(12, 26, "Second Christmas Day")
            let easter = WorkdayCalendar.easter(year)
            for (offset, name) in [(-2, "Good Friday"), (1, "Easter Monday"), (39, "Ascension"), (50, "Whit Monday")] {
                values.append(HolidayOccurrence(date: easter.addingDays(offset)!, name: name))
            }
        } else if region == "US" {
            fixed(1, 1, "New Year")
            // A Saturday January 1 is observed in the preceding calendar year.
            if year < 9999 { fixed(1, 1, "New Year", year + 1) }
            nth(1, .monday, 3, "Martin Luther King Jr. Day"); nth(2, .monday, 3, "Washington's Birthday")
            let mayEnd = date(year, 5, 31)
            values.append(HolidayOccurrence(date: mayEnd.addingDays(-((mayEnd.dayOfWeek.rawValue - DayOfWeek.monday.rawValue + 7) % 7))!, name: "Memorial Day"))
            fixed(6, 19, "Juneteenth"); fixed(7, 4, "Independence Day")
            nth(9, .monday, 1, "Labour Day"); nth(10, .monday, 2, "Columbus Day")
            fixed(11, 11, "Veterans Day"); nth(11, .thursday, 4, "Thanksgiving"); fixed(12, 25, "Christmas")
        }
        for custom in customHolidays.dates where (custom.year == nil || custom.year == year) && custom.day <= DateOnly.daysInMonth(year, custom.month) {
            values.append(HolidayOccurrence(date: date(year, custom.month, custom.day), name: "Custom holiday"))
        }
        // DistinctBy(date) keeps the first occurrence; OrderBy is stable.
        var seen = Set<DateOnly>()
        return values.filter { seen.insert($0.date).inserted }.stableSorted { $0.date < $1.date }
    }

    /// Gregorian ecclesiastical computus (integer arithmetic, not astronomical full moons).
    private static func easter(_ year: Int) -> DateOnly {
        let a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451, n = h + l - 7 * m + 114
        return DateOnly(year, n / 31, n % 31 + 1)!
    }

    static func == (a: WorkdayCalendar, b: WorkdayCalendar) -> Bool { a.region == b.region && a.customHolidays == b.customHolidays }
    func hash(into hasher: inout Hasher) { hasher.combine(region); hasher.combine(customHolidays) }
}

/// A count of working days under one captured calendar (C# record WorkdayPeriod).
final class WorkdayPeriod: Hashable, CustomStringConvertible {
    static let maxCount = 10_000
    let count: Int, calendar: WorkdayCalendar
    /// Validates like C#'s WorkdayPeriod.Checked(), which runs when the period becomes a SheetValue.
    init(_ count: Int, _ calendar: WorkdayCalendar) throws {
        if abs(Int64(count)) > Int64(WorkdayPeriod.maxCount) { throw CalcError.arithmetic("Working-day count limit exceeded (10,000)") }
        self.count = count; self.calendar = calendar
    }
    /// `period with { Count = … }`.
    func with(count: Int) throws -> WorkdayPeriod { try WorkdayPeriod(count, calendar) }
    static func == (a: WorkdayPeriod, b: WorkdayPeriod) -> Bool { a.count == b.count && a.calendar == b.calendar }
    func hash(into hasher: inout Hasher) { hasher.combine(count); hasher.combine(calendar) }
    var description: String { String(count) + (abs(count) == 1 ? " working day" : " working days") }
    var display: String { get throws { description } }
}
