import Foundation

extension HelperArithmetic {
    static let riegelBasis = "Riegel's endurance model: T2 = T1 * (D2 / D1)^1.06 with the exponent fixed at 1.06; computed in double precision and kept to 12 significant digits (approximate); shown in whole seconds; a prediction for comparable efforts, with the distance ratio limited to 1/100..100"
    private static var secondsPerKilometre: UnitExpression { get throws { try UnitExpression.single(UnitCatalog.byId("s")).combine(.single(UnitCatalog.byId("km")), -1) } }
    private static func clock(_ seconds: Rational, _ approximate: Bool = false) throws -> SheetValue {
        .practical(try PracticalValue.forClock(try HelperArithmetic.seconds(seconds, approximate), seconds))
    }
    private static func effort(_ distance: SheetValue, _ time: SheetValue) throws -> (metres: Rational, seconds: Rational) {
        (try quantity(distance, length, "Distance", "length"), try quantity(time, HelperArithmetic.time, "Time", "time"))
    }
    func pace(_ distance: SheetValue, _ time: SheetValue) throws -> Outcome {
        let (metres, seconds) = try HelperArithmetic.effort(distance, time); let perMetre = try seconds / metres
        let pace = NumericValue(ExactNumber(perMetre), unit: try HelperArithmetic.secondsPerKilometre).with { $0.isApproximate = HelperArithmetic.approximate(distance, time) }
        return (.practical(try PracticalValue.forPace(pace, perMetre)), "pace",
                "Pace = elapsed time / distance, shown as m:ss per kilometre and per mile (1 mi = 1609.344 m); whole seconds, halves up; exact value kept")
    }
    func runTime(_ distance: SheetValue, _ pace: SheetValue) throws -> Outcome {
        let metres = try HelperArithmetic.quantity(distance, HelperArithmetic.length, "Distance", "length")
        let perMetre = try HelperArithmetic.quantity(pace, HelperArithmetic.timePerLength, "Pace", "time-per-distance")
        return (try HelperArithmetic.clock(try metres * perMetre, HelperArithmetic.approximate(distance, pace)), "time at pace",
                "Time = distance * pace; shown as m:ss below one hour and h:mm:ss from one hour, whole seconds, halves up; exact value kept")
    }
    func race(_ distance: SheetValue, _ time: SheetValue, _ target: SheetValue) throws -> Outcome {
        let (metres, seconds) = try HelperArithmetic.effort(distance, time)
        let targetMetres = try HelperArithmetic.quantity(target, HelperArithmetic.length, "Target distance", "length")
        let ratio = try targetMetres / metres
        if try ratio.above(Rational(100)) || Rational(1, 100).above(ratio) { throw CalcError.arithmetic("Riegel predictions are limited to a distance change between 1/100 and 100 times") }
        if ratio == .one {
            return (try HelperArithmetic.clock(seconds, HelperArithmetic.approximate(distance, time)), "race prediction", HelperArithmetic.riegelBasis + "; target equals the given distance, time unchanged")
        }
        // Foundation.pow is the same C library pow .NET's Math.Pow calls on this platform; 12 significant digits absorb any last-bit difference.
        let predicted = try FormulaNumbers.fromDouble(FormulaNumbers.toDouble(seconds) * Foundation.pow(FormulaNumbers.toDouble(ratio), 1.06), 12)
        return (try HelperArithmetic.clock(predicted, true), "race prediction", HelperArithmetic.riegelBasis)
    }
}
