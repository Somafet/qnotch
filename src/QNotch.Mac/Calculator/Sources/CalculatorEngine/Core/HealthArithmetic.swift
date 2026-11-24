import Foundation

extension HelperArithmetic {
    static let bmiBasis = "BMI = mass (kg) / height (m)^2 (Quetelet index), shown to one decimal with the exact value kept; no category, target or health advice; bounds 0 < mass <= 1000 kg, 0 < height <= 3 m"
    static let bmrBasis = "Basal metabolic rate, Mifflin-St Jeor (1990): 10 * mass kg + 6.25 * height cm - 5 * age years + 5 (male) or - 161 (female); kilocalories per day at rest, shown to whole kcal with the exact value kept; a population estimate for adults, not medical advice; bounds 0 < mass <= 1000 kg, 0 < height <= 3 m, 0 < age <= 150 years"
    static let tdeeBasis = "Total daily energy expenditure = BMR (Mifflin-St Jeor) * activity factor; kilocalories per day; factors: sedentary 1.2, light 1.375, moderate 1.55, active 1.725, very active 1.9; an estimate, not medical advice"
    static let zoneBasis = "Maximum heart rate = 220 - age (a common population estimate; individual maxima differ widely) or the supplied maximum; zones are 50-60%, 60-70%, 70-80%, 80-90% and 90-100% of that maximum, each boundary rounded to whole bpm (halves up) and shared by neighbouring zones; not medical advice"
    private static let activityFactors: [String: Rational] = [
        "sedentary": try! Rational(12, 10), "light": try! Rational(1375, 1000), "moderate": try! Rational(155, 100), "active": try! Rational(1725, 1000), "very active": try! Rational(19, 10),
    ]
    private static func kilocalories(_ kcal: Rational) throws -> NumericValue {
        let unit = UnitCatalog.byId("kcal")
        return NumericValue(ExactNumber(try kcal * unit.factor), unit: try .single(unit)).with { $0.displayDecimalPlaces = 0 }
    }
    private static func age(_ value: SheetValue) throws -> Rational {
        let age = try plain(value, "Age")
        if try age.sign <= 0 || age.above(Rational(150)) { throw CalcError.arithmetic("Age must be above 0 and at most 150 years") }
        return age
    }
    private func body(_ mass: SheetValue, _ height: SheetValue) throws -> (mass: Rational, height: Rational) {
        let kilograms = try HelperArithmetic.quantity(mass, HelperArithmetic.mass, "Mass", "mass"), metres = try HelperArithmetic.quantity(height, HelperArithmetic.length, "Height", "length")
        if try kilograms.above(Rational(1000)) { throw CalcError.arithmetic("Mass must be at most 1000 kg") }
        if try metres.above(Rational(3)) { throw CalcError.arithmetic("Height must be at most 3 m") }
        return (kilograms, metres)
    }
    func bmi(_ mass: SheetValue, _ height: SheetValue) throws -> Outcome {
        let (kilograms, metres) = try body(mass, height)
        let value = NumericValue(ExactNumber(try kilograms / (metres * metres))).with { $0.displayDecimalPlaces = 1; $0.isApproximate = HelperArithmetic.approximate(mass, height) }
        return (HelperArithmetic.result(value), "bmi", HelperArithmetic.bmiBasis)
    }
    private func bmrValue(_ inputs: [SheetValue], _ sex: String) throws -> Rational {
        let (kilograms, metres) = try body(inputs[0], inputs[1]); let age = try HelperArithmetic.age(inputs[2])
        let bmr = try Rational(10) * kilograms + Rational(625, 100) * metres * Rational(100) - Rational(5) * age + Rational(sex == "male" ? 5 : -161)
        if bmr.sign <= 0 { throw CalcError.arithmetic("The Mifflin-St Jeor estimate is not positive for these inputs") }
        return bmr
    }
    func bmr(_ inputs: [SheetValue], _ sex: String) throws -> Outcome {
        let value = try HelperArithmetic.kilocalories(try bmrValue(inputs, sex)).with { $0.isApproximate = HelperArithmetic.approximate(inputs) }
        return (HelperArithmetic.result(value), "bmr", HelperArithmetic.bmrBasis + "; " + sex)
    }
    func tdee(_ inputs: [SheetValue], _ sex: String, _ level: String) throws -> Outcome {
        let factor = HelperArithmetic.activityFactors[level]!
        let value = try HelperArithmetic.kilocalories(try bmrValue(inputs, sex) * factor).with { $0.isApproximate = HelperArithmetic.approximate(inputs) }
        return (HelperArithmetic.result(value), "tdee", HelperArithmetic.tdeeBasis + "; " + sex + ", " + level + " (" + factor.description + ")")
    }
    func heartZones(_ value: SheetValue, _ mode: String) throws -> Outcome {
        let maximum = mode == "age" ? try Rational(220) - HelperArithmetic.age(value) : try HelperArithmetic.plain(value, "Maximum heart rate")
        if try maximum.sign <= 0 || maximum.above(Rational(300)) { throw CalcError.arithmetic("Maximum heart rate must be above 0 and at most 300 bpm") }
        let edges = try (5...10).map { tenths in PracticalValue.round(try maximum * Rational(tenths, 10)).intValue! }
        let zones = (0..<5).map { HeartRateZone(number: $0 + 1, low: edges[$0], high: edges[$0 + 1]) }
        return (.practical(PracticalValue.forZones(zones)), "heart-rate zones", HelperArithmetic.zoneBasis + "; maximum " + maximum.description + " bpm")
    }
}
