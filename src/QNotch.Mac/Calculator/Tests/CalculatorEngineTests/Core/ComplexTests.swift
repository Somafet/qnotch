import XCTest
@testable import CalculatorEngine

final class ComplexTests: XCTestCase {
    private func last(_ source: String) throws -> LineResult { try MathSheet.line(source) }
    private func value(_ source: String) throws -> SheetValue { try MathSheet.value(source) }
    private func real(_ source: String) throws -> Double { MathSheet.double(try value(source).number.exact.rational) }

    func testPublishedReferenceExamples() throws {
        try theory([("(3 + 4i) * (1 - 2i)", "11 - 2i"), ("sqrt(-4)", "2i")]) { source, display in
            let value = try value(source); XCTAssertEqual(value.kind, .complex, source); XCTAssertEqual(try value.display, display, source)
        }
    }
    func testDisplayFormsAreExactAndPasteBack() throws {
        try theory([
            ("i", "i"), ("-i", "-i"), ("4i", "4i"), ("2.5i", "2.5i"), (".5i", "0.5i"), ("1 + i", "1 + i"), ("-3 - 4i", "-3 - 4i"), ("1/3 + 2/3*i", "1/3 + (2/3)*i"),
            ("sqrt(-2)", "sqrt(2)*i"), ("sqrt(-12)", "2*sqrt(3)*i"), ("sqrt(2) + sqrt(3)*i", "sqrt(2) + sqrt(3)*i"), ("(1 + sqrt(2))*i", "(1 + sqrt(2))*i"),
            ("1 - (1 + sqrt(2))*i", "1 - (1 + sqrt(2))*i"),
        ]) { source, display in
            let value = try value(source)
            XCTAssertEqual(try value.display, display, source); XCTAssertEqual(try value.copyText, display, source); XCTAssertFalse(try value.complex.isApproximate, source)
            XCTAssertEqual(value, try self.value(try value.copyText), source)
        }
    }
    // Field axioms over exact Gaussian rationals. Each difference must be an exact real zero.
    func testFieldIdentitiesHoldExactly() throws {
        try theory([("3+4i", "1-2i", "-2+7i"), ("1/2+1/3*i", "-5+7i", "2i"), ("sqrt(2)+i", "1-sqrt(3)*i", "3")]) { z, w, u in
            for identity in [
                "(\(z))*(\(w)) - (\(w))*(\(z))", "(\(z))+(\(w)) - ((\(w))+(\(z)))", "((\(z))+(\(w)))-(\(w)) - (\(z))", "((\(z))*(\(w)))/(\(w)) - (\(z))",
                "(\(z))*((\(w))+(\(u))) - ((\(z))*(\(w)) + (\(z))*(\(u)))", "((\(z))*(\(w)))*(\(u)) - (\(z))*((\(w))*(\(u)))", "(\(z))*(1/(\(z))) - 1",
                "conj((\(z))*(\(w))) - conj(\(z))*conj(\(w))", "abs((\(z))*(\(w)))^2 - abs(\(z))^2*abs(\(w))^2",
            ] {
                let result = try value(identity)
                XCTAssertEqual(result.kind, .number, identity); XCTAssertEqual(try result.display, "0", identity); XCTAssertFalse(try result.number.isApproximate, identity)
            }
        }
    }
    func testConjugateProductIsTheSquaredNorm() throws {
        try theory([(3, 4), (5, -12), (-7, 24)]) { a, b in
            let z = "(\(a) + \(b)*i)"
            XCTAssertEqual(try value("\(z) * conj(\(z))").display, String(a * a + b * b))
            XCTAssertEqual(try value("abs(\(z))").display, NetFormat.double(Double(a * a + b * b).squareRoot(), nil))
        }
    }
    func testPowersAndQuotientsMatchHandComputedValues() throws {
        try theory([
            ("(1+2i)/(3-4i)", "-0.2 + 0.4i"), ("1/i", "-i"), ("i^2", "-1"), ("i^3", "-i"), ("i^4", "1"), ("i^-1", "-i"), ("(2+i)^3", "2 + 11i"),
            ("(1+i)^10", "32i"), ("(1+i)^-2", "-0.5i"), ("(1+i)^0", "1"),
            ("(1+i)^1024", "13407807929942597099574024998205846127479365820592393377723561443721764030073546976801874298166903427690031858186486050853753882811946569946433649006084096"),
        ]) { source, display in XCTAssertEqual(try value(source).display, display, source) }
    }
    func testPrincipalRootsSquareBackExactly() throws {
        try theory([
            ("sqrt(-4)", "2i"), ("sqrt(-1/4)", "0.5i"), ("sqrt(3+4i)", "2 + i"), ("sqrt(5-12i)", "3 - 2i"), ("sqrt(2i)", "1 + i"), ("sqrt(-2i)", "1 - i"),
            ("sqrt(-3+4i)", "1 + 2i"), ("(3+4i)^0.5", "2 + i"), ("(-4)^0.5", "2i"), ("(-4)^1.5", "-8i"), ("(-4)^-0.5", "-0.5i"),
        ]) { source, display in XCTAssertEqual(try value(source).display, display, source) }
    }
    func testRealRadicalsAndPrincipalBranchRemainExact() throws {
        XCTAssertEqual(try value("sqrt(-2)^2").display, "-2")
        XCTAssertEqual(try value("sqrt(-2)*sqrt(-3)").display, "-sqrt(6)") // Not sqrt(6): the product rule fails across the branch cut.
        XCTAssertEqual(try value("abs(1+i)").display, "sqrt(2)")
        XCTAssertEqual(try value("sqrt(2)").display, "sqrt(2)"); XCTAssertEqual(try value("4^0.5").display, "2")
    }
    func testRootsWithoutASimpleExactFormAreMarkedApproximate() throws {
        let root = try value("sqrt(1+i)")
        XCTAssertTrue(try root.complex.isApproximate); XCTAssertTrue(try root.display.hasPrefix("≈ "))
        // |sqrt(1+i)|^2 = sqrt(2) and sqrt(1+i)^2 = 1+i, both within double rounding at 12 significant digits.
        MathSheet.inRange(try real("abs(sqrt(1+i))^2"), 2.0.squareRoot() - 1e-9, 2.0.squareRoot() + 1e-9)
        MathSheet.inRange(try real("re(sqrt(1+i)^2)"), 1 - 1e-9, 1 + 1e-9); MathSheet.inRange(try real("im(sqrt(1+i)^2)"), 1 - 1e-9, 1 + 1e-9)
        XCTAssertTrue(try value("sqrt(-pi)").complex.isApproximate)
        MathSheet.inRange(try real("im(sqrt(-pi))"), 1.7724538509 - 1e-9, 1.7724538509 + 1e-9)
        XCTAssertTrue(try value("abs(1234567891+987654321i)").number.isApproximate)
    }
    func testApproximationPropagatesThroughEveryPart() throws {
        let product = try value("pi*i")
        XCTAssertTrue(try product.complex.isApproximate); XCTAssertEqual(try product.display, "≈ 3.14159265359i"); XCTAssertEqual(try product.copyText, "3.14159265358979i")
        XCTAssertTrue(try value("re(pi + i)").number.isApproximate); XCTAssertTrue(try value("(pi*i)^2").number.isApproximate)
        XCTAssertTrue(try last("pi*i").explanation.last!.assumption!.hasPrefix("Approximate input/result"))
    }
    func testArgIsThePrincipalAngle() throws {
        try theory([("arg(1+i)", Double.pi / 4), ("arg(-1)", Double.pi), ("arg(-i)", -Double.pi / 2), ("arg(-1-i)", -3 * Double.pi / 4)]) { source, expected in
            let value = try value(source)
            XCTAssertTrue(try value.number.isApproximate, source); MathSheet.inRange(try real(source), expected - 1e-10, expected + 1e-10, source)
        }
    }
    func testPartsAndArgOfRealNumbers() throws {
        XCTAssertEqual(try value("re(3+4i)").display, "3"); XCTAssertEqual(try value("im(3+4i)").display, "4"); XCTAssertEqual(try value("conj(3+4i)").display, "3 - 4i")
        XCTAssertEqual(try value("re(5)").display, "5"); XCTAssertEqual(try value("im(5)").display, "0"); XCTAssertEqual(try value("conj(5)").display, "5")
        XCTAssertEqual(try value("arg(5)").display, "0"); XCTAssertFalse(try value("arg(5)").number.isApproximate)
        MathSheet.inRange(try real("arg(1+sqrt(3)*i)"), Double.pi / 3 - 1e-10, Double.pi / 3 + 1e-10)
    }
    func testAZeroImaginaryPartCollapsesToARealNumber() throws {
        try theory([("i*i", "-1"), ("(1+2i)-(1+2i)", "0"), ("(1+2i)+(1-2i)", "2"), ("0i", "0"), ("0i + 1", "1"), ("(1+i)*(1-i)", "2")]) { source, display in
            let value = try value(source)
            XCTAssertEqual(value.kind, .number, source); XCTAssertEqual(try value.display, display, source); XCTAssertEqual(value, try self.value(display), source)
            XCTAssertEqual(try self.value("(\(source)) + 2").display, display == "0" ? "2" : String(Int(display)! + 2), source)
        }
    }
    func testAUserVariableNamedIAlwaysWins() throws {
        let results = try SheetEvaluator.evaluate("i = 5\ni\n2*i\ni^2")
        XCTAssertEqual(results.map(\.display), ["5", "5", "10", "25"])
        for result in results { XCTAssertEqual(result.value?.kind, .number) }
        XCTAssertNotNil(try last("i = 5\n4i").error) // No implicit multiplication: the variable never silently becomes the imaginary unit.
        XCTAssertEqual(try last("I = 5\n2*i").display, "10") // Sheet names ignore case, so this variable shadows i too.
        let update = try FunctionUpdate.prepare("twice(i) = i + i", .empty, [])
        XCTAssertEqual(try SheetEvaluationSession().evaluateWithFunctions("twice(3)", update.library, []).results[0].display, "6")
    }
    func testProseAndUppercaseStayProse() throws {
        try theory(["I", "i think so", "i in km"]) { source in
            let result = try SheetEvaluator.evaluate(source)[0]; XCTAssertNil(result.value, source); XCTAssertNil(result.error, source)
        }
    }
    func testLabelsBeforeNumbersStayLabels() throws { XCTAssertEqual(try value("i 5").display, "5") }
    func testASpacedSuffixIsNotTheImaginaryUnit() throws { XCTAssertEqual(try last("4 i").error, "Unexpected text") }
    func testUnitsMoneyPercentagesAndCollectionsAreRefused() throws {
        try theory(["(1+2i) m", "5 m + i", "i * 2 kg", "(1+2i) USD", "$5 * i", "$5 + i", "10% + i", "[1,2] * i", "(1+i) per month"]) { source in
            let result = try last(source)
            XCTAssertNil(result.value, source); XCTAssertTrue(result.error?.contains("plain numbers") == true, "\(source): \(result.error ?? "nil")")
        }
    }
    func testUnsupportedOperationsFailExplicitly() throws {
        try theory([
            ("sqrt(-4 m^2)", "no real square root"), ("[1, i]", "Lists require"), ("[[1, i], [2, 3]]", "Lists require"), ("2^i", "exponent"), ("i^i", "exponent"),
            ("i^(1/3)", "exponent"), ("i^pi", "exponent"), ("(1+i)^1025", "exponent"), ("i!", "Unsupported"), ("i%", "Unsupported"), ("(1+i)/0", "Division by zero"),
            ("arg(0)", "undefined"), ("sin(i)", "dimensionless"), ("solve x + i = 0", "real-valued"), ("integral(i*x, 0, 1)", "real-valued"), ("re(1, 2)", "expects 1"),
        ]) { source, message in
            let result = try last(source)
            XCTAssertNil(result.value, source); XCTAssertTrue(result.error?.contains(message) == true, "\(source): \(result.error ?? "nil")")
        }
    }
    func testAggregatesSkipComplexLinesWithoutCrashing() throws {
        let results = try SheetEvaluator.evaluate("1 + i\n3\n5\nsum\naverage")
        XCTAssertEqual(results[3].display, "8"); XCTAssertEqual(results[4].display, "4")
        XCTAssertTrue(results[3].explanation.last?.assumption?.contains("complex") == true)
        XCTAssertEqual(try last("1 + i #t\n3 #t\nsum #t").display, "3")
    }
    func testRoundingAppliesToEachPart() throws {
        XCTAssertEqual(try value("(1/3 + 2/3*i) to 2 decimals").display, "0.33 + 0.67i")
        XCTAssertEqual(try value("i to 2 decimals").display, "i")
        XCTAssertEqual(try value("(0.3 + 0.01i) to 1 decimals").display, "0.3") // A part rounded to zero collapses as well.
    }
    func testScalingAndDependenciesWork() throws {
        XCTAssertEqual(try value("half of (2+4i)").display, "1 + 2i")
        XCTAssertEqual(try last("z = 1 + i\ndouble z").display, "2 + 2i"); XCTAssertEqual(try last("z = 1 + i\nhalf z").display, "0.5 + 0.5i"); XCTAssertEqual(try value("2 of i").display, "2i")
        let results = try SheetEvaluator.evaluate("z = 1 + 2i\nz^2\nz * conj(z)")
        XCTAssertEqual(results[1].display, "-3 + 4i"); XCTAssertEqual(results[2].display, "5"); XCTAssertEqual(results[1].dependencies, [0])
        XCTAssertTrue(try last("sqrt(-4)").explanation.last?.assumption?.contains("rincipal") == true)
    }
    func testSavedFunctionsParseCanonicalizeAndReload() throws {
        let update = try FunctionUpdate.prepare("rotate(z) = z * (1 + 2i)\nnorm2(z) = z * conj(z)", .empty, [])
        XCTAssertEqual(update.library.minimumCatalogVersion, FunctionLibrary.latestCatalogVersion); XCTAssertEqual(FunctionLibrary.latestCatalogVersion, 5)
        let reloaded = try FunctionLibrary(update.library.definitions)
        XCTAssertEqual(update.library.fingerprint, reloaded.fingerprint)
        XCTAssertEqual(reloaded.fingerprint, try FunctionLibrary(update.library.definitions.map { FunctionDefinition(name: $0.name, parameters: $0.parameters, body: $0.body.netReplace(" ", "")) }).fingerprint)
        let results = try SheetEvaluationSession().evaluateWithFunctions("rotate(3 + 4i)\nnorm2(3 + 4i)", reloaded, []).results
        XCTAssertEqual(results.map(\.display), ["-5 + 10i", "25"])
        MathSheet.throwsFormat { try FunctionLibrary([FunctionDefinition(name: "conj", parameters: ["z"], body: "z")]) }
    }
    func testCancellationPropagates() throws {
        let cancelled = CancellationToken(); cancelled.cancel()
        MathSheet.throwsError(.cancelled) { try SheetEvaluator.evaluate("(1+i)^1024", cancelled) }
    }
}
