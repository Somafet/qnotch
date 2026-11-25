import Foundation

// .NET's DateOnly, TimeOnly, DateTime (unspecified kind) and TimeSpan constants, and the NodaTime
// pieces the engine uses (Instant, Offset, zone rules). Proleptic Gregorian, years 1 through 9999, ticks
// of 100 ns. The engine never uses Foundation's Date or Calendar for calculation.

enum Ticks {
    static let perMillisecond: Int64 = 10_000
    static let perSecond: Int64 = 10_000_000
    static let perMinute: Int64 = 600_000_000
    static let perHour: Int64 = 36_000_000_000
    static let perDay: Int64 = 864_000_000_000
    /// DateTime.MaxValue.Ticks.
    static let maxDateTime: Int64 = 3_155_378_975_999_999_999
    /// Ticks from 0001-01-01 to 1970-01-01.
    static let unixEpoch: Int64 = 621_355_968_000_000_000
}

/// System.DayOfWeek (Sunday = 0).
enum DayOfWeek: Int, CaseIterable {
    case sunday = 0, monday, tuesday, wednesday, thursday, friday, saturday
    var name: String { ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][rawValue] }
    /// Enum.TryParse<DayOfWeek>(text, ignoreCase: true): a name, or ANY integer (C# accepts undefined values),
    /// with surrounding white space, or a comma-separated list of those (values ORed).
    static func netTryParse(_ text: String) -> Int? {
        let parts = text.netSplit(",")
        var result = 0
        for raw in parts {
            let part = raw.netTrim
            if part.isEmpty { return nil }
            if let first = part.utf16.first, NetChar.isAsciiDigit(first) || first == 0x2D || first == 0x2B {
                guard let value = Int32(part) else { return nil }
                result |= Int(value)
            } else if let day = DayOfWeek.allCases.first(where: { $0.name.equalsIgnoreCase(part) }) {
                result |= day.rawValue
            } else { return nil }
        }
        return result
    }
}

/// System.DateOnly.
struct DateOnly: Hashable, Comparable, CustomStringConvertible {
    /// Days since 0001-01-01.
    let dayNumber: Int
    static let minValue = DateOnly(dayNumber: 0)
    static let maxValue = DateOnly(dayNumber: 3_652_058)
    init(dayNumber: Int) { self.dayNumber = dayNumber }
    /// `new DateOnly(y, m, d)`; nil where C# throws ArgumentOutOfRangeException.
    init?(_ year: Int, _ month: Int, _ day: Int) {
        guard year >= 1, year <= 9999, month >= 1, month <= 12, day >= 1, day <= DateOnly.daysInMonth(year, month) else { return nil }
        dayNumber = DateOnly.days(year, month, day)
    }
    static func isLeapYear(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }
    static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month { case 2: return isLeapYear(year) ? 29 : 28; case 4, 6, 9, 11: return 30; default: return 31 }
    }
    private static let cumulative = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365]
    private static func days(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let p = y - 1
        return p * 365 + p / 4 - p / 100 + p / 400 + cumulative[m - 1] + (m > 2 && isLeapYear(y) ? 1 : 0) + d - 1
    }
    /// (year, month, day), using .NET's algorithm.
    var parts: (year: Int, month: Int, day: Int) {
        var n = dayNumber
        let y400 = n / 146_097; n -= y400 * 146_097
        var y100 = n / 36_524; if y100 == 4 { y100 = 3 }; n -= y100 * 36_524
        let y4 = n / 1_461; n -= y4 * 1_461
        var y1 = n / 365; if y1 == 4 { y1 = 3 }; n -= y1 * 365
        let year = y400 * 400 + y100 * 100 + y4 * 4 + y1 + 1
        let leap = DateOnly.isLeapYear(year)
        var month = 1
        while true {
            let next = DateOnly.cumulative[month] + (month >= 2 && leap ? 1 : 0)
            if n < next { break }
            month += 1
        }
        let start = DateOnly.cumulative[month - 1] + (month > 2 && leap ? 1 : 0)
        return (year, month, n - start + 1)
    }
    var year: Int { parts.year }
    var month: Int { parts.month }
    var day: Int { parts.day }
    var dayOfYear: Int { dayNumber - DateOnly.days(year, 1, 1) + 1 }
    var dayOfWeek: DayOfWeek { DayOfWeek(rawValue: (dayNumber + 1) % 7)! }
    /// AddDays; nil where C# throws ArgumentOutOfRangeException.
    func addingDays(_ days: Int) -> DateOnly? {
        let n = dayNumber + days
        return n >= 0 && n <= DateOnly.maxValue.dayNumber ? DateOnly(dayNumber: n) : nil
    }
    /// AddMonths (the day clamps to the month's end); nil out of range.
    func addingMonths(_ months: Int) -> DateOnly? {
        let (y, m, d) = parts
        let total = y * 12 + (m - 1) + months
        let year = total >= 0 ? total / 12 : (total - 11) / 12
        let month = total - year * 12 + 1
        guard year >= 1, year <= 9999 else { return nil }
        return DateOnly(year, month, min(d, DateOnly.daysInMonth(year, month)))
    }
    func addingYears(_ years: Int) -> DateOnly? { addingMonths(years * 12) }
    /// ToDateTime(TimeOnly.MinValue).
    var midnight: NetDateTime { NetDateTime(ticks: Int64(dayNumber) * Ticks.perDay) }
    static func < (a: DateOnly, b: DateOnly) -> Bool { a.dayNumber < b.dayNumber }
    /// ToString("yyyy-MM-dd").
    var description: String {
        let (y, m, d) = parts
        return pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2)
    }
    /// DateOnly.TryParseExact(text, "yyyy-MM-dd", InvariantCulture).
    static func parseISO(_ text: String) -> DateOnly? {
        let u = text.units
        guard u.count == 10, u[4] == 0x2D, u[7] == 0x2D, [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ NetChar.isAsciiDigit(u[$0]) }) else { return nil }
        func n(_ a: Int, _ b: Int) -> Int { Int(u[a..<b].string)! }
        return DateOnly(n(0, 4), n(5, 7), n(8, 10))
    }
}

/// Zero-padded decimal (C# "D2", "00", "0000").
func pad(_ value: Int, _ width: Int) -> String {
    let text = String(abs(value))
    return (value < 0 ? "-" : "") + (text.count >= width ? text : String(repeating: "0", count: width - text.count) + text)
}
func pad(_ value: Int64, _ width: Int) -> String { pad(Int(value), width) }

/// System.TimeOnly: ticks within one day.
struct TimeOnly: Hashable, Comparable {
    let ticks: Int64
    static let minValue = TimeOnly(ticks: 0)
    init(ticks: Int64) { precondition(ticks >= 0 && ticks < Ticks.perDay); self.ticks = ticks }
    var hour: Int { Int(ticks / Ticks.perHour) }
    var minute: Int { Int(ticks / Ticks.perMinute % 60) }
    var second: Int { Int(ticks / Ticks.perSecond % 60) }
    var fraction: Int64 { ticks % Ticks.perSecond }
    static func < (a: TimeOnly, b: TimeOnly) -> Bool { a.ticks < b.ticks }
    /// "HH:mm".
    var hhmm: String { pad(hour, 2) + ":" + pad(minute, 2) }
    /// "HH:mm:ss".
    var hhmmss: String { hhmm + ":" + pad(second, 2) }
    /// "HH:mm:ss.fffffff".
    var hhmmss7: String { hhmmss + "." + pad(fraction, 7) }
}

/// System.DateTime with DateTimeKind.Unspecified: ticks since 0001-01-01T00:00.
struct NetDateTime: Hashable, Comparable, CustomStringConvertible {
    let ticks: Int64
    static let maxValue = NetDateTime(ticks: Ticks.maxDateTime)
    init(ticks: Int64) { self.ticks = ticks }
    /// The checked constructor: nil where C# throws ArgumentOutOfRangeException.
    static func checked(_ ticks: Int64) -> NetDateTime? { ticks >= 0 && ticks <= Ticks.maxDateTime ? NetDateTime(ticks: ticks) : nil }
    var date: DateOnly { DateOnly(dayNumber: Int(ticks / Ticks.perDay)) }
    var timeOfDay: TimeOnly { TimeOnly(ticks: ticks % Ticks.perDay) }
    func addingTicks(_ delta: Int64) -> NetDateTime? {
        let (sum, overflow) = ticks.addingReportingOverflow(delta)
        return overflow ? nil : NetDateTime.checked(sum)
    }
    func addingDays(_ days: Int) -> NetDateTime? {
        let (scaled, o1) = Int64(days).multipliedReportingOverflow(by: Ticks.perDay)
        return o1 ? nil : addingTicks(scaled)
    }
    func addingMonths(_ months: Int) -> NetDateTime? {
        guard let moved = date.addingMonths(months) else { return nil }
        return NetDateTime(ticks: Int64(moved.dayNumber) * Ticks.perDay + timeOfDay.ticks)
    }
    static func < (a: NetDateTime, b: NetDateTime) -> Bool { a.ticks < b.ticks }
    /// "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF" then TrimEnd('.'), as LocalTimestamp prints.
    var description: String {
        var fraction = pad(timeOfDay.fraction, 7)
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return date.description + "T" + timeOfDay.hhmmss + (fraction.isEmpty ? "" : "." + fraction)
    }
}

/// NodaTime.Instant at 100 ns resolution: ticks since the Unix epoch.
struct Instant: Hashable, Comparable {
    let unixTicks: Int64
    init(unixTicks: Int64) { self.unixTicks = unixTicks }
    static func < (a: Instant, b: Instant) -> Bool { a.unixTicks < b.unixTicks }
    /// Instant.FromUtc(1, 1, 1, 0, 0).
    static let minSupported = Instant(unixTicks: -Ticks.unixEpoch)
    /// Instant.FromDateTimeUtc(DateTime.MaxValue).
    static let maxSupported = Instant(unixTicks: Ticks.maxDateTime - Ticks.unixEpoch)
    /// The UTC DateTime of this instant (nil outside DateTime's range).
    var utcDateTime: NetDateTime? { NetDateTime.checked(unixTicks + Ticks.unixEpoch) }
}

/// NodaTime.DateTimeZone: offsets for instants and the candidate offsets for a local time.
protocol ZoneRules: AnyObject {
    var id: String { get }
    /// The UTC offset (seconds) in effect at an instant.
    func offsetSeconds(at instant: Instant) -> Int
    /// DateTimeZone.MapLocal: the offsets under which `local` (ticks since 0001-01-01) exists, earlier first.
    /// Empty for a skipped time, two for an ambiguous one.
    func mapLocal(_ local: Int64) -> [Int]
}

/// NodaTime's FixedDateTimeZone: DateTimeZone.Utc, DateTimeZone.ForOffset, and TZDB's fixed zones (Etc/GMT+2, …).
/// Unlike other zones, fixed zones compare by value in C# (FixedDateTimeZone overrides Equals: offset, id, name).
final class FixedZone: ZoneRules {
    let id: String
    let offset: Int
    static let utc = FixedZone(offset: 0)
    /// DateTimeZone.ForOffset: id "UTC", or "UTC±HH", "UTC±HH:mm", "UTC±HH:mm:ss" (FixedDateTimeZone.MakeId).
    convenience init(offset: Int) {
        let m = abs(offset), h = m / 3600, minutes = m % 3600 / 60, seconds = m % 60
        let text = minutes == 0 && seconds == 0 ? pad(h, 2) : seconds == 0 ? pad(h, 2) + ":" + pad(minutes, 2) : pad(h, 2) + ":" + pad(minutes, 2) + ":" + pad(seconds, 2)
        self.init(id: offset == 0 ? "UTC" : (offset < 0 ? "UTC-" : "UTC+") + text, offset: offset)
    }
    init(id: String, offset: Int) { self.id = id; self.offset = offset }
    func offsetSeconds(at instant: Instant) -> Int { offset }
    func mapLocal(_ local: Int64) -> [Int] { [offset] }
}

/// C#'s DateTimeZone equality: reference identity, except fixed zones, which compare by offset and id.
func sameZone(_ a: ZoneRules, _ b: ZoneRules) -> Bool {
    if a === b { return true }
    if let a = a as? FixedZone, let b = b as? FixedZone { return a.offset == b.offset && a.id == b.id }
    return false
}

extension ZoneRules {
    /// The local DateTime ticks of an instant in this zone.
    func localTicks(_ instant: Instant) -> Int64 { instant.unixTicks + Ticks.unixEpoch + Int64(offsetSeconds(at: instant)) * Ticks.perSecond }
}
