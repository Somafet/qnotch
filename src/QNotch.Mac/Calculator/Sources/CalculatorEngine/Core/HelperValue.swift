import Foundation

enum PracticalKind { case heartRateZones, pace, clockTime }
struct HeartRateZone: Hashable { let number: Int, low: Int, high: Int }

/// Presentation of a practical-helper result. A pace or clock time keeps its exact magnitude in `original` and arithmetic uses that magnitude
/// (the m:ss rounding is display only); heart-rate zones carry no single magnitude and are excluded from arithmetic and block totals.
/// C# compares these by reference (a class without Equals), so equality here is identity.
final class PracticalValue: Hashable, CustomStringConvertible {
    let kind: PracticalKind
    let original: NumericValue?
    let zones: [HeartRateZone]
    let display: String
    var copyText: String { display }
    var isApproximate: Bool { original?.isApproximate == true }
    private init(_ kind: PracticalKind, _ original: NumericValue?, _ zones: [HeartRateZone], _ display: String) {
        self.kind = kind; self.original = original; self.zones = zones; self.display = display
    }
    static func forZones(_ zones: [HeartRateZone]) -> PracticalValue {
        PracticalValue(.heartRateZones, nil, zones, zones.map { "Z" + String($0.number) + " " + String($0.low) + "–" + String($0.high) }.joined(separator: " · "))
    }
    /// Seconds per metre in `secondsPerMetre`; shown per kilometre and per mile.
    static func forPace(_ original: NumericValue, _ secondsPerMetre: Rational) throws -> PracticalValue {
        PracticalValue(.pace, original, [], (original.isApproximate ? "≈ " : "") + (try clock(secondsPerMetre * Rational(1000))) + " /km · " +
                       (try clock(secondsPerMetre * Rational(1609344, 1000))) + " /mi")
    }
    static func forClock(_ original: NumericValue, _ seconds: Rational) throws -> PracticalValue {
        PracticalValue(.clockTime, original, [], (original.isApproximate ? "≈ " : "") + (try clock(seconds)))
    }
    /// m:ss below one hour, h:mm:ss from one hour; whole seconds, halves away from zero.
    static func clock(_ seconds: Rational) throws -> String {
        var whole = round(seconds); let negative = whole.sign < 0; whole = whole.magnitude
        let (hours, rest) = whole.quotientAndRemainder(dividingBy: 3600); let (minutes, secs) = rest.quotientAndRemainder(dividingBy: 60)
        func two(_ value: BigInt) -> String { value.description.netPadLeft(2, "0") }
        let text = hours.isZero ? minutes.description + ":" + two(secs) : hours.description + ":" + two(minutes) + ":" + two(secs)
        return negative ? "-" + text : text
    }
    /// The nearest integer, halves away from zero.
    static func round(_ value: Rational) -> BigInt {
        let twice = value.numerator.magnitude * 2 + value.denominator
        let magnitude = twice / (value.denominator * 2)
        return value.numerator.sign < 0 ? -magnitude : magnitude
    }
    static func == (a: PracticalValue, b: PracticalValue) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    var description: String { display }
}
