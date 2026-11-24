import Foundation

extension HelperArithmetic {
    static let fuelUnits = "mpg is the US gallon (3.785411784 L), mpg uk the imperial gallon (4.54609 L); l/100km and mpg are reciprocal, so 235.2146 / (l/100km) = US mpg"
    static let fuelBasis = "Fuel = distance at consumption: volume per distance (l/100km) multiplies, distance per volume (mpg, km/l) divides; " + fuelUnits + "; two-decimal display, exact value kept"
    static let offsetBasis = "Offset of the second zone minus offset of the first, in UTC offsets: positive means the second place's clock is ahead"
    func fuelTrip(_ inputs: [SheetValue]) throws -> Outcome {
        let metres = try HelperArithmetic.quantity(inputs[0], HelperArithmetic.length, "Distance", "length")
        let number = try HelperArithmetic.numberOf(inputs[1], "Consumption")
        let form = number.unit?.fuelForm() ?? 0
        if try form == 0 || !number.isRational || number.exact.rational.sign <= 0 { throw CalcError.arithmetic("Consumption must be a positive fuel unit such as 6.5 l/100km or 36 mpg") }
        let cubicMetres = form == 1 ? try metres * number.exact.rational : try metres / number.exact.rational
        let volume = NumericValue(ExactNumber(cubicMetres), unit: try number.unit!.fuelVolume()).with { $0.displayDecimalPlaces = 2; $0.isApproximate = HelperArithmetic.approximate(inputs) }
        if inputs.count == 2 { return (HelperArithmetic.result(volume), "fuel for distance", HelperArithmetic.fuelBasis) }
        let cost = try MoneyArithmetic(math, context, reads).binary("*", HelperArithmetic.result(volume), inputs[2])
        return (cost, "fuel cost", HelperArithmetic.fuelBasis + "; cost = volume * supplied price per volume")
    }
    func timeDifference(_ inputs: [SheetValue], _ first: String, _ second: String) throws -> Outcome {
        let instant: Instant
        if inputs.count == 1 {
            guard case .date(let date) = inputs[0] else { throw CalcError.arithmetic("Expected a date") }
            instant = Instant(unixTicks: Int64(date.dayNumber) * Ticks.perDay + 12 * Ticks.perHour - Ticks.unixEpoch) // Instant.FromUtc(y, m, d, 12, 0)
        } else { reads.dependencies.insert(.instant); instant = try context.requireNow() }
        let (firstZone, version) = try ZoneCatalog.resolve(first, context, reads), (secondZone, _) = try ZoneCatalog.resolve(second, context, reads)
        let a = firstZone.offsetSeconds(at: instant), b = secondZone.offsetSeconds(at: instant)
        let value = try TimeArithmetic.duration(Int64(b - a) * Ticks.perSecond)
        return (HelperArithmetic.result(value), "time difference", HelperArithmetic.offsetBasis + "; " + first + " " + HelperArithmetic.offsetText(a) + ", " + second + " " +
                HelperArithmetic.offsetText(b) + " at " + HelperArithmetic.instantText(instant) + (inputs.count == 1 ? " (12:00 UTC on the given date)" : " (evaluation instant snapshot)") +
                "; rules " + version)
    }
    /// NodaTime Offset.ToString() (general pattern): +HH, +HH:mm or +HH:mm:ss, whichever loses nothing; zero is +00.
    private static func offsetText(_ seconds: Int) -> String {
        let magnitude = abs(seconds), hours = magnitude / 3600, minutes = magnitude / 60 % 60, rest = magnitude % 60
        func two(_ value: Int) -> String { String(value).netPadLeft(2, "0") }
        return (seconds < 0 ? "-" : "+") + two(hours) + (minutes == 0 && rest == 0 ? "" : ":" + two(minutes)) + (rest == 0 ? "" : ":" + two(rest))
    }
    /// NodaTime Instant.ToString() (general pattern): uuuu-MM-ddTHH:mm:ssZ, with any fraction of a second dropped.
    private static func instantText(_ instant: Instant) -> String {
        let ticks = instant.unixTicks + Ticks.unixEpoch
        let days = ticks >= 0 ? ticks / Ticks.perDay : (ticks - Ticks.perDay + 1) / Ticks.perDay
        let date = DateOnly(dayNumber: Int(days)), timeOfDay = ticks - days * Ticks.perDay
        func two(_ value: Int64) -> String { String(value).netPadLeft(2, "0") }
        return date.description + "T" + two(timeOfDay / Ticks.perHour) + ":" + two(timeOfDay / Ticks.perMinute % 60) + ":" + two(timeOfDay / Ticks.perSecond % 60) + "Z"
    }
}
