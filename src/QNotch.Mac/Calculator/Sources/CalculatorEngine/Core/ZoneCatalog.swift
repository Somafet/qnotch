import Foundation

/// NodaTime.IDateTimeZoneProvider: zone rules by IANA id, under one version id.
protocol TimeZoneProvider: AnyObject {
    var versionId: String { get }
    func zone(_ id: String) -> ZoneRules?
}

/// Immutable host-local rules (C# LocalZoneSnapshot).
final class LocalZoneSnapshot {
    let version: String
    let rules: ZoneRules
    init(_ zone: ZoneRules, version: String) throws {
        if version.netTrim.isEmpty { throw CalcError.argument("The value cannot be an empty string or composed entirely of whitespace. (Parameter 'version')") }
        self.version = version; rules = zone
    }
}

enum ZoneCatalog {
    private struct Tables { var ids = Set<String>(); var aliases = NetDictionary<String, String>.ignoringCase(); var version = "" }
    private static let tables: Tables = {
        do {
            let root = try JSONNode.parse(CalculatorEngine.resource("TimeZones.json"))
            var t = Tables()
            t.version = try root.property("version").string()
            t.ids = Set(try root.property("ids").arrayItems().map { try $0.string() })
            for (name, value) in try root.property("aliases").objectProperties() {
                guard t.aliases.tryAdd(name, try value.string()) else { throw CalcError.argument("An item with the same key has already been added. Key: " + name) }
            }
            if t.ids.count > 1024 || t.aliases.count > 1024 || t.aliases.values.contains(where: { !t.ids.contains($0) }) { throw CalcError.invalidData("Invalid time-zone manifest") }
            return t
        } catch { fatalError("Invalid time-zone manifest: \(error)") }
    }()
    /// "TZDB: 2026f (mapping: 49)", the version the bundled rules must report.
    static var manifestVersion: String { tables.version }
    static var ids: Set<String> { tables.ids }
    static func idLength(_ text: [UInt16], _ start: Int) -> Int {
        func idChar(_ c: UInt16) -> Bool { NetChar.isAsciiLetterOrDigit(c) || c == 0x2F || c == 0x5F || c == 0x2D || c == 0x2B }
        var end = start
        while end < text.count && end - start < 128 && idChar(text[end]) { end += 1 }
        var cursor = end
        while cursor > start {
            if cursor == text.count || !(NetChar.isAsciiLetterOrDigit(text[cursor]) || text[cursor] == 0x2F || text[cursor] == 0x5F) {
                let candidate = text[start..<cursor]
                if candidate.contains(where: { $0 == 0x2F || $0 == 0x2D || $0 == 0x2B }) && tables.ids.contains(String(units: candidate)) { return cursor - start }
            }
            cursor -= 1
        }
        return 0
    }
    static func tryAlias(_ name: String) -> String? {
        if name.equalsIgnoreCase("local") { return "@LOCAL" }
        if name.equalsIgnoreCase("UTC") || name.equalsIgnoreCase("GMT") || name == "Z" { return "UTC" }
        if let id = tables.aliases[name] { return id }
        if tables.ids.contains(name) { return name }
        return nil
    }
    static func resolve(_ id: String, _ context: EvaluationContext, _ reads: ContextReads) throws -> (zone: ZoneRules, version: String) {
        if id == "@LOCAL" { let local = try context.requireLocalZone(reads); return (local.rules, local.version) }
        if id == "UTC" { return (FixedZone.utc, "fixed offset") }
        if id.hasPrefix("UTC") && id.netLength > 3 {
            let u = id.units
            let parts = id.netSubstring(4).netSplit(":")
            if (u[3] != 0x2B && u[3] != 0x2D) || parts.count < 2 || parts.count > 3 || parts.contains(where: { $0.netLength != 2 || !$0.utf16.allSatisfy(NetChar.isAsciiDigit) }) {
                throw CalcError.format("UTC offset requires ±HH:mm[:ss]")
            }
            let h = Int(parts[0])!, m = Int(parts[1])!, s = parts.count == 3 ? Int(parts[2])! : 0
            if h > 18 || m > 59 || s > 59 || h == 18 && (m != 0 || s != 0) { throw CalcError.arithmetic("UTC offset must be within ±18:00") }
            return (FixedZone(offset: (h * 3600 + m * 60 + s) * (u[3] == 0x2D ? -1 : 1)), "fixed offset")
        }
        reads.dependencies.insert(.zoneRules)
        let provider = context.zones
        guard let zone = provider.zone(id) else { throw CalcError.arithmetic("Time-zone rules unavailable: " + id) }
        return (zone, provider.versionId)
    }
}

final class TimestampArithmetic {
    let context: EvaluationContext, reads: ContextReads
    init(_ context: EvaluationContext, _ reads: ContextReads) { self.context = context; self.reads = reads }
    static func join(_ date: SheetValue, _ time: SheetValue) throws -> SheetValue {
        guard let joined = try date.date.midnight.addingTicks(try time.time.totalTicks) else { throw CalcError.arithmetic("Timestamp range exceeded") }
        return .localTimestamp(LocalTimestamp(joined))
    }
    func now() throws -> SheetValue {
        reads.dependencies.formUnion([.instant, .secondTick])
        return .zonedMoment(try ZonedMoment(try context.requireNow(), FixedZone.utc, "fixed offset"))
    }
    func zone(_ value: SheetValue, _ id: String, _ conversion: Bool, _ ambiguity: String) throws -> SheetValue {
        let (zone, version) = try ZoneCatalog.resolve(id, context, reads)
        var value = value
        if conversion {
            if value.kind != .zonedMoment { value = try local(value, ambiguity) }
            return .zonedMoment(try ZonedMoment(try value.moment.instant, zone, version))
        }
        if value.kind == .time {
            reads.dependencies.insert(.date)
            value = try TimestampArithmetic.join(.date(try context.requireToday()), value)
        }
        if value.kind == .date { value = try TimestampArithmetic.join(value, .time(ClockTime(.minValue))) }
        return try TimestampArithmetic.resolve(try value.timestamp.value, zone, version, ambiguity)
    }
    func local(_ value: SheetValue, _ ambiguity: String = "") throws -> SheetValue {
        let local = try context.requireLocalZone(reads)
        var value = value
        if value.kind == .time {
            reads.dependencies.insert(.date)
            value = try TimestampArithmetic.join(.date(try context.requireToday()), value)
        }
        if value.kind == .date { value = try TimestampArithmetic.join(value, .time(ClockTime(.minValue))) }
        return try TimestampArithmetic.resolve(try value.timestamp.value, local.rules, local.version, ambiguity)
    }
    static func resolve(_ local: NetDateTime, _ zone: ZoneRules, _ version: String, _ ambiguity: String = "") throws -> SheetValue {
        let mapping = zone.mapLocal(local.ticks)
        if mapping.isEmpty { throw CalcError.arithmetic("Skipped local time in " + zone.id) }
        if mapping.count == 2 && ambiguity.isEmpty { throw CalcError.arithmetic("Ambiguous local time; specify earlier or later in " + zone.id) }
        let offset = ambiguity == "later" ? mapping[mapping.count - 1] : mapping[0]
        return .zonedMoment(try ZonedMoment(Instant(unixTicks: local.ticks - Ticks.unixEpoch - Int64(offset) * Ticks.perSecond), zone, version))
    }
    static func unix(_ value: SheetValue, _ export: Bool) throws -> SheetValue {
        if export { return .number(NumericValue(try Rational(BigInt(try value.moment.instant.unixTicks), BigInt(Ticks.perSecond)))) }
        if try value.isPercentage || value.number.isApproximate { throw CalcError.arithmetic("Unix seconds require an exact plain rational") }
        let ticks = try value.scalar * Rational(Ticks.perSecond)
        if !ticks.denominator.isOne { throw CalcError.arithmetic("Unix precision is at most 100 nanoseconds") }
        if ticks.numerator < BigInt(-621_355_968_000_000_000) || ticks.numerator > BigInt(Int64(2_534_023_007_999_999_999)) { throw CalcError.arithmetic("Unix timestamp range exceeded") }
        return .zonedMoment(try ZonedMoment(Instant(unixTicks: ticks.numerator.int64Value!), FixedZone.utc, "fixed offset"))
    }
    static func isTimestamp(_ value: SheetValue) -> Bool { value.kind == .localTimestamp || value.kind == .zonedMoment }
    static func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue {
        let rangeError = CalcError.arithmetic("Timestamp range exceeded")
        if isTimestamp(left) && isTimestamp(right) {
            if operation != "-" || left.kind != right.kind { throw CalcError.arithmetic("Subtract timestamps of the same type") }
            return .number(try TimeArithmetic.duration(left.kind == .localTimestamp ? try left.timestamp.value.ticks - right.timestamp.value.ticks :
                try left.moment.instant.unixTicks - right.moment.instant.unixTicks))
        }
        if operation != "+" && operation != "-" || operation == "-" && !isTimestamp(left) { throw CalcError.arithmetic("Invalid timestamp arithmetic") }
        let stamp = isTimestamp(left) ? left : right, offset = isTimestamp(left) ? right : left, sign = operation == "-" ? -1 : 1
        if offset.kind == .calendarPeriod {
            let period = try offset.period
            let local = stamp.kind == .localTimestamp ? try stamp.timestamp.value : try stamp.moment.local
            guard let moved = local.addingMonths(period.months * sign)?.addingDays(period.days * sign) else { throw rangeError }
            if stamp.kind == .localTimestamp { return .localTimestamp(LocalTimestamp(moved)) }
            let moment = try stamp.moment
            return try resolve(moved, moment.zone, moment.ruleVersion)
        }
        let ticks = try TimeArithmetic.ticks(offset) * BigInt(sign)
        if ticks.magnitude > BigInt(Ticks.maxDateTime) { throw CalcError.arithmetic("Timestamp shift range exceeded") }
        let delta = ticks.int64Value!
        if stamp.kind == .localTimestamp {
            guard let moved = try stamp.timestamp.value.addingTicks(delta) else { throw rangeError }
            return .localTimestamp(LocalTimestamp(moved))
        }
        let moment = try stamp.moment
        let (sum, overflow) = moment.instant.unixTicks.addingReportingOverflow(delta)
        if overflow { throw rangeError }
        return .zonedMoment(try ZonedMoment(Instant(unixTicks: sum), moment.zone, moment.ruleVersion))
    }
}
