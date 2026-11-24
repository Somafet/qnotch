import Foundation

enum TimeSyntax {
    static func literalLength(_ source: [UInt16], _ start: Int) -> Int {
        var cursor = start
        while cursor < source.count && cursor - start < 3 && NetChar.isAsciiDigit(source[cursor]) { cursor += 1 }
        if cursor == start || cursor >= source.count || source[cursor] != 0x3A { return 0 }
        while cursor < source.count && cursor - start < 32 && (NetChar.isAsciiDigit(source[cursor]) || source[cursor] == 0x3A || source[cursor] == 0x2E) { cursor += 1 }
        return cursor - start
    }
    static func isMeridiem(_ text: String) -> Bool { text.equalsIgnoreCase("am") || text.equalsIgnoreCase("pm") }
    /// int.TryParse(text, NumberStyles.None): ASCII digits only, within Int32.
    static func parseDigits(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf16.allSatisfy(NetChar.isAsciiDigit) else { return nil }
        guard let value = Int(text), value <= Int(Int32.max) else { return nil }
        return value
    }
    static func parse(_ text: String, _ meridiem: String? = nil) throws -> ClockTime {
        let parts = text.netSplit(":")
        guard parts.count >= 2, parts.count <= 3, (1...2).contains(parts[0].netLength), parts[1].netLength == 2,
              var hour = parseDigits(parts[0]), let minute = parseDigits(parts[1]), minute <= 59 else { throw CalcError.format("Invalid clock time") }
        var ticks: Int64 = 0
        if parts.count == 3 {
            let seconds = parts[2].netSplit(".")
            guard seconds.count <= 2, seconds[0].netLength == 2, let second = parseDigits(seconds[0]), second <= 59 else { throw CalcError.format("Invalid clock seconds") }
            ticks = Int64(second) * Ticks.perSecond
            if seconds.count == 2 {
                if seconds[1].netLength < 1 || seconds[1].netLength > 7 || !seconds[1].utf16.allSatisfy(NetChar.isAsciiDigit) {
                    throw CalcError.format("Clock precision is at most seven fractional second digits")
                }
                ticks += Int64(seconds[1].netPadRight(7, "0"))!
            }
        }
        if let meridiem {
            if hour < 1 || hour > 12 { throw CalcError.format("AM/PM clock hour must be from 1 to 12") }
            hour = hour % 12 + (meridiem.equalsIgnoreCase("pm") ? 12 : 0)
        }
        if hour == 24 && minute == 0 && ticks == 0 { return ClockTime(.minValue, 1) }
        if hour > 23 { throw CalcError.format("Clock hour must be from 0 to 23 (or 24:00)") }
        return ClockTime(TimeOnly(ticks: Int64(hour) * Ticks.perHour + Int64(minute) * Ticks.perMinute + ticks))
    }
    static func duration(_ value: ExactNumber, includeDays: Bool = false) throws -> String {
        if !value.isRational {
            let exact = "(" + (try value.text()) + ") s"
            if exact.netLength > 2048 { throw CalcError.arithmetic("Output limit exceeded") }
            return exact
        }
        let seconds = value.constant; let numerator = seconds.numerator.magnitude, denominator = seconds.denominator
        var (hours, remainder) = numerator.quotientAndRemainder(dividingBy: denominator * 3600)
        let minutes: BigInt
        (minutes, remainder) = remainder.quotientAndRemainder(dividingBy: denominator * 60)
        var pieces: [String] = []
        if includeDays {
            let days: BigInt
            (days, hours) = hours.quotientAndRemainder(dividingBy: 24)
            if !days.isZero { pieces.append(days.description + " day") }
        }
        if !hours.isZero { pieces.append(hours.description + " h") }
        if !minutes.isZero { pieces.append(minutes.description + " min") }
        if !remainder.isZero || pieces.isEmpty {
            let part = try Rational(remainder, denominator).description
            pieces.append((part.contains("/") ? "(" + part + ")" : part) + " s")
        }
        let fractions = pieces.contains { $0.contains("/") }
        var text = pieces.joined(separator: fractions ? " + " : " ")
        if fractions && pieces.count > 1 { text = "(" + text + ")" }
        if seconds.sign < 0 { text = "-(" + text + ")" }
        if text.netLength > 2048 { throw CalcError.arithmetic("Output limit exceeded") }
        return text
    }
}

enum TimeArithmetic {
    static let timeDimension = Dimension(0, 0, 1, 0, 0, 0, 0, 0)
    static let workedKind = "workedTime"
    static func range(_ start: SheetValue, _ end: SheetValue) throws -> SheetValue {
        let a = try start.time, b = try end.time; var ticks = b.totalTicks - a.totalTicks
        if b.dayOffset == a.dayOffset && ticks < 0 { ticks += Ticks.perDay }
        if ticks < 0 { throw CalcError.arithmetic("Interval ends before its explicit starting day") }
        return .number(try duration(ticks, worked: true))
    }
    static func duration(_ ticks: Int64, worked: Bool = false) throws -> NumericValue {
        NumericValue(ExactNumber(try Rational(BigInt(ticks), BigInt(Ticks.perSecond))), unit: try .single(UnitCatalog.byId("s")))
            .with { $0.useCompoundDuration = true; $0.quantityKind = worked ? workedKind : "" }
    }
    static func ticks(_ value: SheetValue) throws -> BigInt {
        let number = try value.number
        if number.unit?.dimension != timeDimension || !number.isRational || number.isPercentage || number.isApproximate {
            throw CalcError.arithmetic("Clock shifts require an exact rational time duration")
        }
        let ticks = try number.exact.rational * Rational(Ticks.perSecond)
        if !ticks.denominator.isOne { throw CalcError.arithmetic("Clock shift must be an exact multiple of 100 nanoseconds") }
        return ticks.numerator
    }
    static func binary(_ operation: String, _ left: SheetValue, _ right: SheetValue) throws -> SheetValue {
        if left.kind == .time && right.kind == .time {
            if operation != "-" { throw CalcError.arithmetic("Only subtraction is defined between clock readings; use an explicit range for overnight work") }
            return .number(try duration(try left.time.totalTicks - right.time.totalTicks))
        }
        if operation != "+" && operation != "-" || operation == "-" && left.kind != .time { throw CalcError.arithmetic("Invalid clock arithmetic") }
        let clock = left.kind == .time ? try left.time : try right.time
        let ticks = try self.ticks(left.kind == .time ? right : left)
        return .time(try ClockTime.fromTicks(BigInt(clock.totalTicks) + (operation == "-" ? -ticks : ticks)).checked())
    }
}
