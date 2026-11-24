import XCTest
@testable import CalculatorEngine

final class ConstantTests: XCTestCase {
    private func last(_ source: String) throws -> LineResult { try MathSheet.line(source) }
    private func value(_ source: String) throws -> SheetValue { try MathSheet.value(source) }
    private func published(_ text: String) throws -> Rational {
        let parts = text.netSplit("e"); let exponent = parts.count == 2 ? Int(parts[1])! : 0
        let scale = BigInt.pow(10, abs(exponent))
        return try Rational.parse(parts[0]) * (exponent < 0 ? try Rational(.one, scale) : try Rational(scale))
    }
    private func near(_ source: String, _ expected: Double, _ relative: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try value(source).number.exact
        guard value.isRational else { throw AssertionFailure(description: "Expected a rational magnitude") }
        MathSheet.inRange(MathSheet.double(value.constant), expected - abs(expected) * relative, expected + abs(expected) * relative, source, file: file, line: line)
    }

    func testPublishedReferenceExample() throws {
        let value = try value("c")
        XCTAssertEqual(try value.display, "299,792,458 m/s"); XCTAssertEqual(try value.copyText, "299792458 m/s"); XCTAssertFalse(try value.number.isApproximate)
    }
    // Values as printed by NIST for CODATA 2022 and the 2019 SI definitions, inspected 31 October 2026.
    func testPinnedValuesMatchPublishedDigits() throws {
        try theory([
            ("c", "299792458", "m/s", false), ("planck", "6.62607015e-34", "J*s", false), ("elementary_charge", "1.602176634e-19", "C", false),
            ("boltzmann", "1.380649e-23", "J/deltaK", false), ("avogadro", "6.02214076e23", "mol^-1", false), ("standard_gravity", "9.80665", "m/s^2", false),
            ("gravitational_constant", "6.67430e-11", "m^3/kg/s^2", true), ("vacuum_permittivity", "8.8541878188e-12", "F/m", true),
            ("vacuum_permeability", "1.25663706127e-6", "N/A^2", true), ("electron_mass", "9.1093837139e-31", "kg", true), ("proton_mass", "1.67262192595e-27", "kg", true),
        ]) { name, published, unit, measured in
            let value = try value(name).number
            XCTAssertEqual(try value.exact.rational, try self.published(published), name); XCTAssertEqual(value.unit?.symbol, unit, name); XCTAssertEqual(value.isApproximate, measured, name)
        }
    }
    func testMeasuredConstantsRetainUncertaintyAndAreMarked() throws {
        try theory([
            ("gravitational_constant", "0.00015e-11"), ("vacuum_permittivity", "0.0000000014e-12"), ("vacuum_permeability", "0.00000000020e-6"),
            ("electron_mass", "0.0000000028e-31"), ("proton_mass", "0.00000000052e-27"),
        ]) { name, uncertainty in
            let line = try last(name)
            XCTAssertTrue(line.display.hasPrefix("≈ "), name)
            let assumption = try XCTUnwrap(line.explanation.last?.assumption)
            XCTAssertTrue(assumption.contains("CODATA 2022"), name); XCTAssertTrue(assumption.hasPrefix("Approximate input/result"), name)
            XCTAssertTrue(assumption.netSplit("; ")[1].contains(uncertainty), name) // Hover shows the first two segments, so the uncertainty must be among them.
        }
    }
    func testExactnessAndSourceAreExplained() throws {
        try theory([("c", "exact by the 2019 SI definition"), ("standard_gravity", "1901 CGPM"), ("gas_constant", "exact product"), ("hbar", "truncated")]) { name, text in
            XCTAssertTrue(try last(name).explanation.last?.assumption?.contains(text) == true, name)
        }
    }
    // Independent routes between constants. Tolerances come from the published relative uncertainties.
    func testGasConstantIsExactlyAvogadroTimesBoltzmann() throws {
        XCTAssertEqual(try value("gas_constant - avogadro * boltzmann").display, "0 J/deltaK/mol")
        XCTAssertFalse(try value("gas_constant").number.isApproximate)
        XCTAssertTrue(try value("gas_constant").display.hasPrefix("8.314462618"))
    }
    func testReducedPlanckMatchesARecomputationWithFiftyDigitsOfPi() throws {
        let pi = try Rational.parse("3.14159265358979323846264338327950288419716939937510")
        let expected = try published("6.62607015e-34") / (Rational(2) * pi)
        let actual = try value("hbar").number; XCTAssertTrue(actual.isApproximate)
        let difference = try (actual.exact.rational - expected) / expected
        XCTAssertTrue(difference.numerator.magnitude * BigInt.pow(10, 26) < difference.denominator)
        XCTAssertTrue(try actual.display.hasPrefix("≈ 1.054571817")) // NIST prints 1.054 571 817...
    }
    func testPublishedDerivedConstantsAreReproduced() throws {
        try near("elementary_charge * avogadro", 96485.33212, 1e-9) // Faraday constant, exact
        try near("electron_mass * c^2", 8.1871057880e-14, 1e-9) // CODATA 2022 electron mass energy equivalent
        try near("electron_mass * c^2 / elementary_charge", 510998.95069, 1e-9) // 0.51099895069 MeV
        try near("proton_mass / electron_mass", 1836.152673426, 1e-9) // CODATA 2022 proton-electron mass ratio
        try near("boltzmann * 300 deltaK", 4.141947e-21, 1e-12)
    }
    func testVacuumConstantsAgreeWithTheSpeedOfLight() throws {
        // c^2 = 1/(epsilon0 mu0). Both are measured with relative uncertainty near 1.6e-10.
        try near("c^2 * vacuum_permittivity * vacuum_permeability", 1, 5e-10)
        let derived = try value("1/sqrt(vacuum_permittivity * vacuum_permeability)")
        XCTAssertTrue(try derived.number.isApproximate); XCTAssertEqual(try derived.number.unit?.symbol, "m/s")
        try near("1/sqrt(vacuum_permittivity * vacuum_permeability)", 299792458, 5e-10)
    }
    func testMathematicalConstantsSatisfyTheirIdentities() throws {
        XCTAssertEqual(try value("pi").display, "≈ 3.14159265358979"); XCTAssertEqual(try value("tau").display, "≈ 6.28318530717959")
        XCTAssertEqual(try value("e + 0").display, "≈ 2.71828182845905"); XCTAssertEqual(try value("phi").display, "≈ 1.61803398874989")
        XCTAssertEqual(try value("phi^2 - phi - 1").display, "0"); XCTAssertFalse(try value("phi^2 - phi - 1").number.isApproximate) // phi^2 = phi + 1 exactly
        XCTAssertEqual(try value("phi").copyText, "0.5 + 0.5*sqrt(5)"); XCTAssertEqual(try value("(1 + sqrt(5))/2").exact, try value("phi").exact)
        XCTAssertEqual(try value("phi * (phi - 1)").copyText, "1")
        XCTAssertTrue(try value("pi").number.isApproximate); XCTAssertFalse(try value("phi").number.isApproximate)
        try near("tau / pi", 2, 1e-13)
    }
    func testEveryAliasResolvesToTheSameValue() throws {
        try theory([
            ("c", "speed_of_light lightspeed"), ("planck", "planck_constant"), ("hbar", "ħ ℏ reduced_planck"), ("elementary_charge", "e_charge q_e"),
            ("boltzmann", "boltzmann_constant k_B"), ("avogadro", "avogadro_constant N_A"), ("gas_constant", "molar_gas_constant"),
            ("gravitational_constant", "newton_constant G_N"), ("standard_gravity", "g0 g_n"), ("vacuum_permittivity", "epsilon0 eps0 ε0 ε₀"),
            ("vacuum_permeability", "mu0 μ0 µ0 μ₀"), ("electron_mass", "m_e"), ("proton_mass", "m_p"), ("pi", "π"), ("tau", "τ"), ("phi", "φ"),
        ]) { name, aliases in
            for alias in aliases.netSplit(" ") {
                XCTAssertEqual(try value(name), try value(alias), alias); XCTAssertEqual(try value(name + " + " + name), try value(alias + " + " + alias), alias)
            }
        }
    }
    func testUserVariablesWinEverywhere() throws {
        try theory([("c = 5\nc", "5"), ("c = 5\nc * 2", "10"), ("hbar = 2\nhbar", "2"), ("phi = 3\nphi", "3"), ("tau = 4\ntau", "4"), ("planck = 7\nplanck", "7"),
                    ("pi = 3\npi", "3"), ("e = 3\ne", "3")]) { source, display in XCTAssertEqual(try last(source).display, display, source) }
    }
    func testAVariableDefinedLaterStillWins() throws { XCTAssertEqual(try SheetEvaluator.evaluate("c * 2\nc = 5")[0].display, "10") }
    func testParametersWinOverConstants() throws {
        let update = try FunctionUpdate.prepare("f(c) = c * 2", .empty, [])
        XCTAssertEqual(try SheetEvaluationSession().evaluateWithFunctions("f(3)", update.library, []).results[0].display, "6")
    }
    func testUnitsAndMultipliersWinInUnitPosition() throws {
        try theory([
            ("3 h", "3 h"), ("5 m", "5 m"), ("2 g", "2 g"), ("1 kg", "1 kg"), ("5 g0", "5 g0"), ("2 C", "2 C"), ("3 h in min", "180 min"), ("21 celsius in fahrenheit", "69.8 °F"),
            ("100 °C in K", "373.15 K"), ("2k", "2000"), ("5M", "5000000"), ("3 million", "3000000"), ("half of 10", "5"),
        ]) { source, display in XCTAssertEqual(try value(source).display, display, source) }
    }
    func testLowercaseCIsNotACelsiusUnitAndNeverBecomesAMultipleOfLightSpeed() throws {
        try theory(["5 c", "180 c in f"]) { source in
            let result = try last(source); XCTAssertNil(result.value, source); XCTAssertEqual(result.error, "Unexpected text", source)
        }
    }
    func testLabelsBeforeNumbersStayLabels() throws {
        try theory([("c 5", "5"), ("e 5", "5"), ("phi 12", "12")]) { source, display in XCTAssertEqual(try value(source).display, display, source) }
    }
    func testProseStaysProse() throws {
        try theory(["e", "C", "Planck", "Boltzmann", "a b c", "c in f", "c in h", "speed of light"]) { source in
            let result = try SheetEvaluator.evaluate(source)[0]; XCTAssertNil(result.value, source); XCTAssertNil(result.error, source)
        }
    }
    func testConversionsRoundingAndArithmeticKeepCompactNotation() throws {
        try theory([
            ("c in km/s", "299,792.458 km/s"), ("c in m/s", "299,792,458 m/s"), ("standard_gravity in m/s^2", "9.80665 m/s^2"), ("c to 3 sig figs", "300000000 m/s"),
            ("pi to 3 decimals", "≈ 3.142"), ("phi to 4 decimals", "1.618"), ("c * 2", "599,584,916 m/s"), ("2 * c", "599,584,916 m/s"), ("-c", "-299,792,458 m/s"),
            ("c * 5 s", "1,498,962,290 m"), ("pi/3", "≈ 1.0471975511966"),
        ]) { source, display in XCTAssertEqual(try value(source).display, display, source) }
    }
    func testConversionToARepeatingDecimalIsMarkedAsRounded() throws {
        let value = try value("c in mph")
        XCTAssertEqual(try value.display, "≈ 670,616,629.384395 mph"); XCTAssertFalse(try value.number.isApproximate) // 299792458 / 0.44704
        XCTAssertTrue(try value.copyText.contains("/"))
    }
    func testCopyKeepsCompleteDigitsAndPastesBack() throws {
        let value = try value("planck")
        XCTAssertEqual(try value.display, "6.62607015e-34 J*s"); XCTAssertTrue(try value.copyText.hasPrefix("0.000000000000000000000000000000000662607015"))
        XCTAssertEqual(try value.exact, try self.value(try value.copyText).exact); XCTAssertEqual(try self.value("avogadro").display, "6.02214076e23 mol^-1")
        XCTAssertEqual(try self.value("c^2").copyText, "89875517873681764 m^2/s^2") // 299792458^2
    }
    func testOrdinaryNumbersAreNotRegrouped() throws {
        XCTAssertEqual(try value("1000000 m").display, "1000000 m"); XCTAssertEqual(try value("299792458").display, "299792458")
        XCTAssertEqual(try value("$5 * pi").display, "≈ 15.71 USD")
    }
    func testConstantsWorkInsideFormulas() throws {
        XCTAssertEqual(try value("solve x = c").display, "x = 299792458")
        XCTAssertEqual(try value("solve 2x = c").display, "x = 149896229")
        XCTAssertEqual(try value("integral(c*x, 0, 1)").display, "149896229") // c/2 by the polynomial antiderivative
        XCTAssertEqual(try value("derivative(gas_constant/gas_constant*3*x, 7)").display, "3")
        try near("r = solve x = tau\nsolutionRoot(r, 1)", 2 * Double.pi, 1e-9)
        XCTAssertEqual(try value("solve x = phi").display, "x ≈ 1.618")
        try near("derivative(tau*x^2, 1)", 2 * 2 * Double.pi, 1e-9) // 2 tau x at x = 1, through the symbolic path because tau is not rational
        try near("integral(phi*x, 0, 2)", 2 * (1 + 5.0.squareRoot()) / 2, 1e-9) // phi x^2/2 from 0 to 2
    }
    func testMeasuredConstantsMakeFormulaResultsApproximateAndDiscloseTheDroppedUnit() throws {
        let line = try MathSheet.last("solve x = 2 * gravitational_constant")
        XCTAssertTrue(try XCTUnwrap(line.value).equation.isApproximate)
        XCTAssertTrue(line.explanation.contains { $0.assumption?.contains("formulas do not track dimensions") == true && $0.assumption!.contains("0.00015e-11") })
    }
    func testFormulaNamesFollowTheSamePrecedence() throws {
        try theory([("c = 3\nsolve x = c", "x = 3"), ("solve c^2 = 4 for c", "c = -2 or c = 2"), ("hbar = 2\nintegral(hbar*x, 0, 1)", "1")]) { source, display in
            XCTAssertEqual(try last(source).display, display, source)
        }
    }
    func testSavedFunctionsParseCanonicalizeAndReload() throws {
        let update = try FunctionUpdate.prepare("energy(m) = m * c^2\nhalfc(x) = solve 2y = c for y", .empty, [])
        XCTAssertEqual(update.library.minimumCatalogVersion, FunctionLibrary.latestCatalogVersion)
        let reloaded = try FunctionLibrary(update.library.definitions)
        XCTAssertEqual(update.library.fingerprint, reloaded.fingerprint)
        let results = try SheetEvaluationSession().evaluateWithFunctions("energy(2)\nhalfc(0)", reloaded, []).results
        XCTAssertEqual(try XCTUnwrap(results[0].value).copyText.netSplit(" ")[0], "179751035747363528") // 2 * 299792458^2
        XCTAssertEqual(results[1].display, "y = 149896229")
    }
}
