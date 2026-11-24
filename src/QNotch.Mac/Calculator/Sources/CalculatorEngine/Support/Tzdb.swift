import Foundation

// The engine's IANA time-zone rules: NodaTime 3.3.7's embedded TZDB (the C# engine's
// DateTimeZoneProviders.Tzdb), exported losslessly by Tools/TzdbExport into Resources/Tzdb.txt (format described
// there), and NodaTime's own algorithms over that data. Foundation's TimeZone is never used for rules: its
// database is the host's and can differ from the pinned one, so results would drift from the Windows engine.
//
// Ported from NodaTime (Apache 2.0): DateTimeZone.MapLocal with its adjacent-interval heuristics,
// PrecalculatedDateTimeZone, StandardDaylightAlternatingMap, ZoneRecurrence and ZoneYearOffset, so every offset
// and every ambiguous or skipped local time matches C# exactly (see TimeZoneRulesTests, which checks all zones
// against NodaTime-generated hashes).

/// The embedded TZDB rules (NodaTime's TZDB 2026f in C#).
enum Tzdb {
    static let provider: TimeZoneProvider = TzdbProvider(CalculatorEngine.resource("Tzdb.txt"))
}

/// DateTimeZoneProviders.Tzdb: zones by id (canonical ids and links), one cached instance per id so moments keep
/// C#'s reference identity. A link keeps its own id, as in NodaTime.
final class TzdbProvider: TimeZoneProvider {
    let versionId: String
    /// Every id, in file (ordinal) order.
    let ids: [String]
    private let rulesText: [String: Substring]
    private let lock = NSLock()
    private var zones: [String: ZoneRules] = [:]
    private var parsed: [String: TzdbRules] = [:]

    init(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        var version: String?, ids: [String] = [], rules: [String: Substring] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            if line.hasPrefix("V ") { version = String(line.dropFirst(2)); continue }
            guard let space = line.firstIndex(of: " ") else { fatalError("Invalid Tzdb.txt line: " + line) }
            let id = String(line[..<space])
            ids.append(id); rules[id] = line[line.index(after: space)...]
        }
        guard let version else { fatalError("Tzdb.txt has no version") }
        versionId = version; self.ids = ids; rulesText = rules
    }

    func zone(_ id: String) -> ZoneRules? {
        lock.lock(); defer { lock.unlock() }
        if let zone = zones[id] { return zone }
        guard let rules = rulesFor(id) else { return nil }
        let zone: ZoneRules
        switch rules {
        case .fixed(let offset): zone = FixedZone(id: id, offset: offset)
        case .precalculated(let map): zone = TzdbZone(id: id, map)
        }
        zones[id] = zone
        return zone
    }

    private enum TzdbRules { case fixed(Int), precalculated(PrecalculatedMap) }

    /// Parses (once) the rules a line describes, following "=" references.
    private func rulesFor(_ id: String) -> TzdbRules? {
        guard var text = rulesText[id] else { return nil }
        var key = id
        if text.hasPrefix("=") {
            key = String(text.dropFirst())
            guard let target = rulesText[key] else { fatalError("Tzdb.txt: unknown reference " + key) }
            text = target
        }
        if let rules = parsed[key] { return rules }
        let rules = TzdbProvider.parse(key, text)
        parsed[key] = rules
        return rules
    }

    private static func parse(_ id: String, _ text: Substring) -> TzdbRules {
        func int(_ token: Substring) -> Int {
            guard let value = Int(token) else { fatalError("Tzdb.txt: invalid number in " + id) }
            return value
        }
        if text.hasPrefix("F") { return .fixed(int(text.dropFirst())) }
        guard text.hasPrefix("P") else { fatalError("Tzdb.txt: invalid rules for " + id) }
        let tokens = text.dropFirst().split(separator: " ")
        var starts: [Int64] = [NodaTicks.beforeMin], walls = [int(tokens[0])]
        var seconds: Int64 = 0, index = 1
        while index < tokens.count, !tokens[index].hasPrefix("T") {
            let pair = tokens[index].split(separator: ":")
            seconds += Int64(int(pair[0])); starts.append(seconds * Ticks.perSecond); walls.append(int(pair[1]))
            index += 1
        }
        var tail: (start: Int64, map: StandardDaylightAlternatingMap)?
        if index < tokens.count {
            guard tokens.count == index + 4 else { fatalError("Tzdb.txt: invalid tail for " + id) }
            func recurrence(_ token: Substring) -> ZoneRecurrence {
                let f = token.split(separator: "/")
                guard f.count == 8, let mode = ZoneRecurrence.Mode(rawValue: String(f[0])) else { fatalError("Tzdb.txt: invalid recurrence for " + id) }
                return ZoneRecurrence(mode: mode, month: int(f[1]), dayOfMonth: int(f[2]), dayOfWeek: int(f[3]), advance: f[4] == "1",
                                      timeOfDayTicks: Int64(int(f[5])) * Ticks.perMillisecond, addDay: f[6] == "1", savings: int(f[7]))
            }
            let start = (seconds + Int64(int(tokens[index].dropFirst()))) * Ticks.perSecond
            tail = (start, StandardDaylightAlternatingMap(standardOffset: int(tokens[index + 1]), standard: recurrence(tokens[index + 2]), daylight: recurrence(tokens[index + 3])))
        }
        return .precalculated(PrecalculatedMap(starts: starts, walls: walls, tail: tail))
    }
}

// MARK: - NodaTime's instant model

/// NodaTime Instant / LocalInstant values as Int64 ticks since the (local) Unix epoch. Int64.min and Int64.max stand
/// for BeforeMinValue and AfterMaxValue; every other value lies within NodaTime's valid range (years -9998…9999).
enum NodaTicks {
    static let beforeMin = Int64.min, afterMax = Int64.max
    static let minDays = -4_371_222, maxDays = 2_932_896
    static func isValid(_ ticks: Int64) -> Bool { ticks != beforeMin && ticks != afterMax }
    /// Whether Unix ticks lie within Instant.MinValue…MaxValue (day numbers minDays…maxDays).
    static func isInstantInRange(_ ticks: Int64) -> Bool { ticks >= Int64(minDays) * Ticks.perDay && ticks < Int64(maxDays + 1) * Ticks.perDay }
    /// DaysSinceEpoch (floor), including the sentinels' deliberately invalid day numbers.
    static func days(_ ticks: Int64) -> Int {
        if ticks == beforeMin { return -16_777_216 }
        if ticks == afterMax { return 16_777_215 }
        let (q, r) = ticks.quotientAndRemainder(dividingBy: Ticks.perDay)
        return Int(r < 0 ? q - 1 : q)
    }
    /// Instant.SafePlus(offset) and LocalInstant.SafeMinus(-offset): sentinels stay put, results past the valid
    /// range become the matching sentinel.
    static func safeAdd(_ ticks: Int64, seconds offset: Int) -> Int64 {
        if !isValid(ticks) { return ticks }
        let result = ticks + Int64(offset) * Ticks.perSecond
        let day = days(result)
        return day < minDays ? beforeMin : day > maxDays ? afterMax : result
    }
}

/// ISO calendar arithmetic on days since 1970-01-01 (proleptic Gregorian, astronomical years).
enum IsoDays {
    static func fromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
    static func toCivil(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
    static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }
    static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month { case 2: return isLeap(year) ? 29 : 28; case 4, 6, 9, 11: return 30; default: return 31 }
    }
    /// IsoDayOfWeek: Monday 1 … Sunday 7 (1970-01-01 was a Thursday).
    static func isoDayOfWeek(_ days: Int) -> Int { ((days % 7) + 7 + 3) % 7 + 1 }
}

/// NodaTime.TimeZones.ZoneInterval, reduced to what offsets and MapLocal read: raw bounds and the wall offset.
struct ZoneSpan: Equatable {
    let start: Int64, end: Int64, wallOffset: Int
    let localStart: Int64, localEnd: Int64
    init(start: Int64, end: Int64, wallOffset: Int) {
        self.start = start; self.end = end; self.wallOffset = wallOffset
        localStart = NodaTicks.safeAdd(start, seconds: wallOffset); localEnd = NodaTicks.safeAdd(end, seconds: wallOffset)
    }
    func withStart(_ newStart: Int64) -> ZoneSpan { ZoneSpan(start: newStart, end: end, wallOffset: wallOffset) }
    func contains(local: Int64) -> Bool { localStart <= local && local < localEnd }
}

/// NodaTime.TimeZones.ZoneRecurrence with ZoneYearOffset, for an infinite recurrence (every TZDB tail rule).
struct ZoneRecurrence {
    enum Mode: String { case wall = "W", standard = "S", utc = "U" }
    let mode: Mode
    let month: Int, dayOfMonth: Int, dayOfWeek: Int, advance: Bool, timeOfDayTicks: Int64, addDay: Bool
    /// Daylight savings in seconds while this recurrence is in force.
    let savings: Int

    /// ZoneYearOffset.GetRuleOffset.
    func ruleOffset(_ standardOffset: Int, _ previousSavings: Int) -> Int {
        switch mode { case .wall: return standardOffset + previousSavings; case .standard: return standardOffset; case .utc: return 0 }
    }
    /// ZoneYearOffset.GetOccurrenceForYear: the local instant of this year's transition.
    func occurrence(_ year: Int) -> Int64 {
        var day = dayOfMonth > 0 ? dayOfMonth : IsoDays.daysInMonth(year, month) + dayOfMonth + 1
        if month == 2 && dayOfMonth == 29 && !IsoDays.isLeap(year) { day = 28 }
        var date = IsoDays.fromCivil(year, month, day)
        if dayOfWeek != 0 {
            let current = IsoDays.isoDayOfWeek(date)
            if current != dayOfWeek {
                var difference = dayOfWeek - current
                if difference > 0 { if !advance { difference -= 7 } } else if advance { difference += 7 }
                date += difference
            }
        }
        if addDay {
            let civil = IsoDays.toCivil(date)
            if year == 9999 && civil.month == 12 && civil.day == 31 { return NodaTicks.afterMax }
            date += 1
        }
        return Int64(date) * Ticks.perDay + timeOfDayTicks
    }
    /// ZoneRecurrence.Next (FromYear = Int32.MinValue, ToYear = Int32.MaxValue): the first transition after `instant`.
    func next(_ instant: Int64, _ standardOffset: Int, _ previousSavings: Int) -> Int64 {
        let offset = ruleOffset(standardOffset, previousSavings)
        let local = NodaTicks.safeAdd(instant, seconds: offset)
        if local == NodaTicks.afterMax { return NodaTicks.afterMax }
        var year = local == NodaTicks.beforeMin ? -9998 : IsoDays.toCivil(NodaTicks.days(local)).year
        let candidate = NodaTicks.safeAdd(occurrence(year), seconds: -offset)
        if candidate > instant { return candidate }
        year += 1
        if year > 9999 { return NodaTicks.afterMax }
        return NodaTicks.safeAdd(occurrence(year), seconds: -offset)
    }
    /// ZoneRecurrence.PreviousOrSame for an infinite recurrence: the last transition at or before `instant`.
    func previousOrSame(_ instant: Int64, _ standardOffset: Int, _ previousSavings: Int) -> Int64 {
        let offset = ruleOffset(standardOffset, previousSavings)
        let local = NodaTicks.safeAdd(instant, seconds: offset)
        if local == NodaTicks.beforeMin { return NodaTicks.beforeMin }
        var year = local == NodaTicks.afterMax ? 9999 : IsoDays.toCivil(NodaTicks.days(local)).year
        let candidate = NodaTicks.safeAdd(occurrence(year), seconds: -offset)
        if candidate <= instant { return candidate }
        year -= 1
        if year < -9998 { return NodaTicks.beforeMin }
        return NodaTicks.safeAdd(occurrence(year), seconds: -offset)
    }
}

/// NodaTime.TimeZones.StandardDaylightAlternatingMap: a standard offset alternating with daylight time forever.
struct StandardDaylightAlternatingMap {
    let standardOffset: Int
    /// The recurrence into standard time (zero savings) and the one into daylight time.
    let standard: ZoneRecurrence, daylight: ZoneRecurrence

    func interval(_ instant: Int64) -> ZoneSpan {
        let daylightNext = daylight.next(instant, standardOffset, 0)
        let standardNext = standard.next(instant, standardOffset, daylight.savings)
        // `inDaylight`: the recurrence in force is the daylight one (the next transition goes back to standard).
        let inDaylight: Bool
        if standardNext < daylightNext { inDaylight = true }
        else if standardNext > daylightNext { inDaylight = false }
        else {
            if NodaTicks.isValid(standardNext) { fatalError("Zone recurrence rules have identical transitions. This time zone is broken.") }
            let previousDaylight = daylight.previousOrSame(instant, standardOffset, 0)
            let previousStandard = standard.previousOrSame(instant, standardOffset, daylight.savings)
            inDaylight = previousDaylight > previousStandard
        }
        let recurrence = inDaylight ? daylight : standard
        let start = recurrence.previousOrSame(instant, standardOffset, inDaylight ? 0 : daylight.savings)
        return ZoneSpan(start: start, end: inDaylight ? standardNext : daylightNext, wallOffset: standardOffset + recurrence.savings)
    }
}

/// NodaTime.TimeZones.PrecalculatedDateTimeZone's interval lookup: explicit intervals from the start of time, then
/// an optional tail map whose first interval is clamped to start where the explicit ones end.
final class PrecalculatedMap {
    let periods: [ZoneSpan]
    let tail: (start: Int64, map: StandardDaylightAlternatingMap)?
    private let firstTail: ZoneSpan?

    init(starts: [Int64], walls: [Int], tail: (start: Int64, map: StandardDaylightAlternatingMap)?) {
        var periods: [ZoneSpan] = []
        for i in starts.indices {
            let end = i + 1 < starts.count ? starts[i + 1] : tail?.start ?? NodaTicks.afterMax
            periods.append(ZoneSpan(start: starts[i], end: end, wallOffset: walls[i]))
        }
        self.periods = periods; self.tail = tail
        firstTail = tail.map { $0.map.interval($0.start).withStart($0.start) }
    }

    func interval(_ instant: Int64) -> ZoneSpan {
        if let tail, instant >= tail.start {
            let span = tail.map.interval(instant)
            return span.start < tail.start ? firstTail! : span
        }
        var low = 0, high = periods.count
        while low < high {
            let middle = (low + high) / 2, period = periods[middle]
            if period.start > instant { high = middle } else if period.end <= instant { low = middle + 1 } else { return period }
        }
        fatalError("Instant did not exist in time zone")
    }
}

/// A TZDB zone with transitions: NodaTime's DateTimeZone over a precalculated map.
final class TzdbZone: ZoneRules {
    let id: String
    let map: PrecalculatedMap
    init(id: String, _ map: PrecalculatedMap) { self.id = id; self.map = map }

    /// GetZoneInterval for an instant (Unix ticks or a sentinel).
    func interval(_ instant: Int64) -> ZoneSpan { map.interval(instant) }
    func offsetSeconds(at instant: Instant) -> Int { map.interval(instant.unixTicks).wallOffset }

    /// DateTimeZone.MapLocal, including its heuristics: only the interval holding the local instant read as UTC and
    /// its immediate neighbours (within about a day) are considered.
    func mapLocal(_ local: Int64) -> [Int] {
        let localInstant = local - Ticks.unixEpoch
        let interval = map.interval(localInstant)
        if interval.contains(local: localInstant) {
            if let earlier = earlierMatching(interval, localInstant) { return [earlier.wallOffset, interval.wallOffset] }
            if let later = laterMatching(interval, localInstant) { return [interval.wallOffset, later.wallOffset] }
            return [interval.wallOffset]
        }
        if let earlier = earlierMatching(interval, localInstant) { return [earlier.wallOffset] }
        if let later = laterMatching(interval, localInstant) { return [later.wallOffset] }
        return []
    }
    private func earlierMatching(_ interval: ZoneSpan, _ local: Int64) -> ZoneSpan? {
        // Instant arithmetic is in nanoseconds in NodaTime (start - Duration.Epsilon); transitions fall on whole
        // seconds, so one tick earlier lands in the same interval.
        guard NodaTicks.days(local) <= NodaTicks.days(interval.start) + 1 else { return nil }
        let candidate = map.interval(interval.start - 1)
        return candidate.contains(local: local) ? candidate : nil
    }
    private func laterMatching(_ interval: ZoneSpan, _ local: Int64) -> ZoneSpan? {
        guard NodaTicks.days(local) >= NodaTicks.days(interval.end) - 1 else { return nil }
        let candidate = map.interval(interval.end)
        return candidate.contains(local: local) ? candidate : nil
    }
}
