import Foundation

/// A clock reading with an explicit relative day, independent of timezone/instant.
struct ClockTime: Hashable, CustomStringConvertible {
    var time: TimeOnly
    var dayOffset = 0
    init(_ time: TimeOnly, _ dayOffset: Int = 0) { self.time = time; self.dayOffset = dayOffset }
    var totalTicks: Int64 { Int64(dayOffset) * Ticks.perDay + time.ticks }
    func checked() throws -> ClockTime {
        if abs(dayOffset) > 3_660_000 { throw CalcError.arithmetic("Clock day-offset limit exceeded") }
        return self
    }
    static func fromTicks(_ ticks: BigInt) throws -> ClockTime {
        var (day, remainder) = ticks.quotientAndRemainder(dividingBy: BigInt(Ticks.perDay))
        if remainder.sign < 0 { day = day - 1; remainder = remainder + BigInt(Ticks.perDay) }
        if day.magnitude > 3_660_000 { throw CalcError.arithmetic("Clock day-offset limit exceeded") }
        return ClockTime(TimeOnly(ticks: remainder.int64Value!), day.intValue!)
    }
    var description: String {
        var text = time.ticks % Ticks.perMinute == 0 ? time.hhmm : time.hhmmss7
        if text.contains(".") { text = text.netTrimEnd("0").netTrimEnd(".") }
        return dayOffset == 0 ? text : "(" + text + (dayOffset < 0 ? " - " : " + ") + String(abs(dayOffset)) + " day)"
    }
}

struct CalendarPeriod: Hashable, CustomStringConvertible {
    var months: Int
    var days: Int
    init(_ months: Int, _ days: Int) { self.months = months; self.days = days }
    func checked() throws -> CalendarPeriod {
        if abs(months) > 120_000 || abs(days) > 3_660_000 { throw CalcError.arithmetic("Calendar period limit exceeded") }
        return self
    }
    var description: String {
        func monthsText(_ value: Int) -> String { String(value) + (abs(value) == 1 ? " month" : " months") }
        if days == 0 { return monthsText(months) }
        if months == 0 { return String(days) + " day" }
        return "(" + monthsText(months) + (days < 0 ? " - " : " + ") + String(abs(days)) + " day)"
    }
}

/// A Gregorian local date and clock reading, with no implied zone or instant.
struct LocalTimestamp: Hashable, CustomStringConvertible {
    let value: NetDateTime
    init(_ value: NetDateTime) { self.value = value }
    var description: String { value.description }
}

/// An instant plus the zone rules used to present and shift it. No clock or I/O.
struct ZonedMoment: Hashable, CustomStringConvertible {
    let instant: Instant
    let zone: ZoneRules
    let ruleVersion: String
    var zoneId: String { zone.id }
    static let rangeError = "Timestamp range exceeded (years 0001 through 9999 in both UTC and local time)"
    init(_ instant: Instant, _ zone: ZoneRules, _ version: String) throws {
        if instant < Instant.minSupported || instant > Instant.maxSupported { throw CalcError.arithmetic(ZonedMoment.rangeError) }
        let local = zone.localTicks(instant)
        if local < 0 || local > Ticks.maxDateTime { throw CalcError.arithmetic(ZonedMoment.rangeError) }
        self.instant = instant; self.zone = zone; ruleVersion = version
    }
    /// The local date and time in the zone.
    var local: NetDateTime { NetDateTime(ticks: zone.localTicks(instant)) }
    var offsetSeconds: Int { zone.offsetSeconds(at: instant) }
    static func == (a: ZonedMoment, b: ZonedMoment) -> Bool { a.instant == b.instant && a.zone === b.zone && a.ruleVersion == b.ruleVersion }
    func hash(into hasher: inout Hasher) { hasher.combine(instant); hasher.combine(ruleVersion) }
    var description: String {
        let offset = offsetSeconds, magnitude = abs(offset)
        let suffix = offset == 0 ? "Z" : (offset < 0 ? "-" : "+") + pad(magnitude / 3600, 2) + ":" + pad(magnitude / 60 % 60, 2) + (magnitude % 60 == 0 ? "" : ":" + pad(magnitude % 60, 2))
        return LocalTimestamp(local).description + suffix
    }
}
