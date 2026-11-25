import Foundation

/// .NET `DateTimeOffset`: an instant in DateTime ticks (UTC) plus the offset it was observed at.
/// Equality, hashing and ordering use the instant only, as `DateTimeOffset.Equals` does; the offset matters only for text.
struct DateTimeOffset: Hashable, Comparable, CustomStringConvertible {
    let utcTicks: Int64
    /// Offset from UTC in minutes (whole minutes, ±14 h, as .NET requires).
    let offsetMinutes: Int

    static let minValue = DateTimeOffset(utcTicks: 0)
    static let maxValue = DateTimeOffset(utcTicks: Ticks.maxDateTime)

    init(utcTicks: Int64, offsetMinutes: Int = 0) { self.utcTicks = utcTicks; self.offsetMinutes = offsetMinutes }
    /// `new DateTimeOffset(year, month, day, hour, minute, second, offset)`: the fields are local to the offset.
    init(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, offsetMinutes: Int = 0) {
        let date = DateOnly.parseISO(pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2))!
        let local = date.midnight.ticks + Int64(hour) * Ticks.perHour + Int64(minute) * Ticks.perMinute + Int64(second) * Ticks.perSecond
        self.init(utcTicks: local - Int64(offsetMinutes) * Ticks.perMinute, offsetMinutes: offsetMinutes)
    }

    /// `DateTimeOffset.UtcNow`.
    static var utcNow: DateTimeOffset {
        var spec = timespec()
        clock_gettime(CLOCK_REALTIME, &spec)
        return DateTimeOffset(utcTicks: Ticks.unixEpoch + Int64(spec.tv_sec) * Ticks.perSecond + Int64(spec.tv_nsec) / 100)
    }

    var localTicks: Int64 { utcTicks + Int64(offsetMinutes) * Ticks.perMinute }
    /// `UtcDateTime`.
    var utcDateTime: NetDateTime { NetDateTime(ticks: utcTicks) }
    func addingTicks(_ ticks: Int64) -> DateTimeOffset { DateTimeOffset(utcTicks: utcTicks + ticks, offsetMinutes: offsetMinutes) }
    func adding(seconds: Double) -> DateTimeOffset { addingTicks(Int64((seconds * Double(Ticks.perSecond)).rounded())) }
    func adding(minutes: Int) -> DateTimeOffset { addingTicks(Int64(minutes) * Ticks.perMinute) }
    func adding(hours: Int) -> DateTimeOffset { addingTicks(Int64(hours) * Ticks.perHour) }
    func adding(days: Int) -> DateTimeOffset { addingTicks(Int64(days) * Ticks.perDay) }
    /// `ToOffset`: the same instant shown at another offset.
    func toOffset(minutes: Int) -> DateTimeOffset { DateTimeOffset(utcTicks: utcTicks, offsetMinutes: minutes) }
    static func - (a: DateTimeOffset, b: DateTimeOffset) -> Int64 { a.utcTicks - b.utcTicks }

    static func == (a: DateTimeOffset, b: DateTimeOffset) -> Bool { a.utcTicks == b.utcTicks }
    func hash(into hasher: inout Hasher) { hasher.combine(utcTicks) }
    static func < (a: DateTimeOffset, b: DateTimeOffset) -> Bool { a.utcTicks < b.utcTicks }
    var description: String { jsonText }

    /// System.Text.Json's form: the "O" round-trip pattern with trailing zero fractions removed and the offset always as ±HH:MM.
    var jsonText: String {
        let local = NetDateTime(ticks: localTicks)
        let date = local.date, time = local.timeOfDay
        var text = pad(date.year, 4) + "-" + pad(date.month, 2) + "-" + pad(date.day, 2) + "T" + time.hhmmss
        if time.fraction != 0 {
            var fraction = pad(time.fraction, 7)
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text += "." + fraction
        }
        let minutes = abs(offsetMinutes)
        return text + (offsetMinutes < 0 ? "-" : "+") + pad(minutes / 60, 2) + ":" + pad(minutes % 60, 2)
    }

    /// System.Text.Json's DateTimeOffset reader (ISO 8601-1:2019 extended profile): `yyyy-MM-dd`, optionally `THH:mm[:ss[.fraction]]`,
    /// optionally `Z`, `±HH` or `±HH:MM`. Fractions beyond seven digits are truncated. Text without an offset is local time, as in C#.
    static func parseJSON(_ text: String) -> DateTimeOffset? {
        let u = Array(text.utf8)
        var i = 0
        func digits(_ count: Int) -> Int? {
            guard i + count <= u.count else { return nil }
            var value = 0
            for k in 0..<count { let c = u[i + k]; guard c >= 48, c <= 57 else { return nil }; value = value * 10 + Int(c - 48) }
            i += count; return value
        }
        func take(_ c: Character) -> Bool { if i < u.count, u[i] == c.asciiValue! { i += 1; return true }; return false }
        guard let year = digits(4), take("-"), let month = digits(2), take("-"), let day = digits(2), year >= 1, (1...12).contains(month),
              day >= 1, day <= DateOnly.daysInMonth(year, month), let date = DateOnly.parseISO(pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)) else { return nil }
        var ticks = date.midnight.ticks
        var offset: Int?
        if i < u.count {
            guard take("T"), let hour = digits(2), take(":"), let minute = digits(2), hour < 24, minute < 60 else { return nil }
            ticks += Int64(hour) * Ticks.perHour + Int64(minute) * Ticks.perMinute
            if take(":") {
                guard let second = digits(2), second < 60 else { return nil }
                ticks += Int64(second) * Ticks.perSecond
                if take(".") {
                    var fraction: Int64 = 0, count = 0
                    while i < u.count, u[i] >= 48, u[i] <= 57 { if count < 7 { fraction = fraction * 10 + Int64(u[i] - 48) }; count += 1; i += 1 }
                    guard count > 0, count <= 16 else { return nil }
                    if count < 7 { for _ in count..<7 { fraction *= 10 } }
                    ticks += fraction
                }
            }
            if take("Z") { offset = 0 }
            else if i < u.count, u[i] == UInt8(ascii: "+") || u[i] == UInt8(ascii: "-") {
                let sign = u[i] == UInt8(ascii: "-") ? -1 : 1; i += 1
                guard let hours = digits(2) else { return nil }
                var minutes = 0
                if take(":") { guard let m = digits(2) else { return nil }; minutes = m }
                guard hours <= 14, minutes < 60, hours * 60 + minutes <= 14 * 60 else { return nil }
                offset = sign * (hours * 60 + minutes)
            }
            guard i == u.count else { return nil }
        }
        let resolved = offset ?? localOffsetMinutes(localTicks: ticks)
        let utc = ticks - Int64(resolved) * Ticks.perMinute
        guard utc >= 0, utc <= Ticks.maxDateTime else { return nil }
        return DateTimeOffset(utcTicks: utc, offsetMinutes: resolved)
    }

    /// The machine's offset for a local wall time (C# reads offset-less text as local time). Only a parsing fallback; nothing the
    /// engine computes depends on it.
    private static func localOffsetMinutes(localTicks: Int64) -> Int {
        let seconds = Double(localTicks - Ticks.unixEpoch) / Double(Ticks.perSecond)
        return TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: seconds)) / 60
    }
}
