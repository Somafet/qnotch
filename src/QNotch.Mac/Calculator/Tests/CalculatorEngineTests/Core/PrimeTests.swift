import XCTest
@testable import CalculatorEngine

final class PrimeTests: XCTestCase {
    private func last(_ source: String) throws -> LineResult { try MathSheet.line(source) }
    private func value(_ source: String) throws -> SheetValue { try MathSheet.value(source) }
    private func exact(_ source: String) throws -> BigInt { try value(source).number.exact.rational.numerator }
    /// Multiplies a displayed factorization back together, so the check does not depend on how the factors were found.
    private func multiply(_ product: String) -> BigInt {
        product.netSplit(" × ").reduce(BigInt.one) { total, part in
            let pieces = part.netSplit("^")
            return total * BigInt.pow(BigInt(pieces[0])!, pieces.count == 2 ? Int(pieces[1])! : 1)
        }
    }
    private func display(_ source: String) throws -> String { try value(source).display }

    func testPublishedReferenceExamples() throws {
        try theory([("isprime(91)", "not prime: 7 × 13"), ("isprime(97)", "prime")]) { source, display in
            let value = try value(source)
            XCTAssertEqual(value.kind, .prime, source); XCTAssertEqual(try value.display, display, source); XCTAssertEqual(try value.copyText, display, source)
        }
    }
    func testSmallIntegersAgreeWithAnIndependentSieve() throws {
        let limit = 1200
        var composite = [Bool](repeating: false, count: limit)
        var p = 2
        while p * p < limit { if !composite[p] { var m = p * p; while m < limit { composite[m] = true; m += p } }; p += 1 }
        for n in 2..<limit {
            let isPrime = try value("isprime(\(n))")
            XCTAssertEqual(try isPrime.prime.isPrime, !composite[n], "\(n)"); XCTAssertTrue(try isPrime.prime.isProven, "\(n)")
            XCTAssertEqual(try isPrime.display, composite[n] ? "not prime: " + (try display("factor(\(n))")) : "prime", "\(n)")
            XCTAssertEqual(multiply(try display("factor(\(n))")), BigInt(n), "\(n)")
        }
    }
    func testZeroAndOneAreNotPrime() throws {
        try theory(["0", "1"]) { n in XCTAssertEqual(try display("isprime(\(n))"), "not prime", n) }
    }
    func testKnownPrimesBelow2To64AreProven() throws {
        try theory(["7919", "104729", "2^13-1", "2^31-1", "2^61-1", "2^32-5", "2^64-59", "18446744073709551557", "2^16+1"]) { n in
            let value = try value("isprime(\(n))")
            XCTAssertEqual(try value.display, "prime", n); XCTAssertTrue(try value.prime.isProven, n); XCTAssertTrue(try value.prime.isPrime, n)
            XCTAssertTrue(try last("isprime(\(n))").explanation.last?.assumption?.contains("proven") == true, n)
        }
    }
    func testPublishedPrimesAboveTheBoundAreProbablePrimesAndSaySo() throws {
        try theory(["2^89-1", "2^107-1", "2^127-1", "2^521-1", "2^607-1", "2^1024-105"]) { n in
            let value = try value("isprime(\(n))")
            XCTAssertEqual(try value.display, "probable prime", n); XCTAssertTrue(try value.prime.isPrime, n); XCTAssertFalse(try value.prime.isProven, n)
            XCTAssertTrue(try last("isprime(\(n))").explanation.last?.assumption?.contains("not a proof") == true, n)
        }
    }
    func testCompositesThatFoolWeakerTestsAreFactoredCompletely() throws {
        try theory([
            "561", "1105", "1729", "2465", "2821", "6601", "8911", "41041", "825265", "321197185", "2047", "1373653", "25326001", "3215031751", "2152302898747",
            "3474749660383", "341550071728321", "3825123056546413051", "2^11-1", "2^23-1", "2^29-1", "2^67-1", "2^32+1", "2^64-1",
        ]) { source in
            let n = try exact(source); let value = try value("isprime(\(source))")
            XCTAssertFalse(try value.prime.isPrime, source); XCTAssertTrue(try value.prime.isProven, source); XCTAssertTrue(try value.display.hasPrefix("not prime: "), source)
            let product = try value.display.netSubstring("not prime: ".netLength)
            XCTAssertEqual(multiply(product), n, source)
            for part in product.netSplit(" × ") { XCTAssertTrue(try display("isprime(\(part.netSplit("^")[0]))").hasPrefix("prime"), part) }
            XCTAssertEqual(try display("factor(\(source))"), product, source)
        }
    }
    func testTheStrongestPublishedPseudoprimesAreCaught() throws {
        try theory([("318665857834031151167461", "399165290221", "798330580441"), ("3317044064679887385961981", "1287836182261", "2575672364521")]) { n, p, q in
            XCTAssertEqual(BigInt(n)!, BigInt(p)! * BigInt(q)!)
            let value = try value("isprime(\(n))")
            XCTAssertFalse(try value.prime.isPrime, n); XCTAssertTrue(try value.display.hasPrefix("not prime"), n)
        }
    }
    func testTheDeterministicBoundIsWhereProofEnds() throws {
        let bound = BigInt("3317044064679887385961981")!
        let below = try SheetEvaluator.evaluate("p = prevprime(\(bound))\nisprime(p)"), above = try SheetEvaluator.evaluate("q = nextprime(\(bound))\nisprime(q)")
        XCTAssertTrue(try XCTUnwrap(below[0].value).number.exact.rational.numerator < bound); XCTAssertTrue(try XCTUnwrap(above[0].value).number.exact.rational.numerator > bound)
        XCTAssertEqual(below[1].display, "prime"); XCTAssertTrue(try XCTUnwrap(below[1].value).prime.isProven)
        XCTAssertEqual(above[1].display, "probable prime"); XCTAssertFalse(try XCTUnwrap(above[1].value).prime.isProven)
    }
    func testFactorizationsMatchPublishedResults() throws {
        try theory([
            ("factor(360)", "2^3 × 3^2 × 5"), ("factor(97)", "97"), ("factor(1)", "1"), ("factor(2^10)", "2^10"), ("factor(2^64-1)", "3 × 5 × 17 × 257 × 641 × 65537 × 6700417"),
            ("factor(2^64+1)", "274177 × 67280421310721"), ("factor(4294967279 * 4294967291)", "4294967279 × 4294967291"), ("factor(1000003^2)", "1000003^2"),
            ("factor(1000003^2 * 1000033)", "1000003^2 × 1000033"), ("factor(2^2 * 3 * 1000003^3)", "2^2 × 3 × 1000003^3"),
        ]) { source, display in
            let value = try value(source)
            XCTAssertEqual(try value.display, display, source); XCTAssertEqual(try value.copyText, display, source); XCTAssertEqual(try value.prime.number, multiply(display), source)
        }
    }
    func testNeighbouringPrimesMatchPublishedGaps() throws {
        try theory([
            ("nextprime(0)", "2"), ("nextprime(1)", "2"), ("nextprime(2)", "3"), ("nextprime(3)", "5"), ("nextprime(90)", "97"), ("nextprime(113)", "127"),
            ("prevprime(3)", "2"), ("prevprime(4)", "3"), ("prevprime(5)", "3"), ("prevprime(100)", "97"), ("prevprime(127)", "113"),
            ("nextprime(2^64)", "18446744073709551629"), ("prevprime(2^64)", "18446744073709551557"),
        ]) { source, display in let value = try value(source); XCTAssertEqual(value.kind, .number, source); XCTAssertEqual(try value.display, display, source) }
    }
    func testInvalidInputsFailExplicitly() throws {
        try theory([
            ("isprime(-7)", "nonnegative"), ("nextprime(-1)", "nonnegative"), ("factor(-12)", "nonnegative"), ("factor(0)", "positive"), ("prevprime(2)", "above 2"),
            ("prevprime(0)", "above 2"), ("isprime(7/2)", "exact integer"), ("isprime(2.5)", "exact integer"), ("isprime(sqrt(2))", "exact integer"),
            ("isprime(pi)", "exact integer"), ("isprime(sin(1))", "exact integer"), ("factor(1 + 0 * pi)", "exact integer"), ("isprime(5 m)", "exact integer"),
            ("factor(5 kg)", "exact integer"), ("isprime(10%)", "exact integer"), ("isprime($5)", "exact integer"), ("isprime(1 + i)", "exact integer"),
            ("isprime(2^1024)", "below 2^1024"), ("factor(2^1024 * 3)", "below 2^1024"), ("isprime(1, 2)", "expects 1"), ("isprime(7) + 1", "not numbers"),
            ("-isprime(7)", "not numbers"), ("factor(12) * 2", "not numbers"),
        ]) { source, message in
            let result = try last(source)
            XCTAssertNil(result.value, source); XCTAssertTrue(result.error?.contains(message) == true, "\(source): \(result.error ?? "nil")")
        }
    }
    func testAdmissibleIntegerFormsAreAccepted() throws {
        XCTAssertEqual(try display("isprime(0x61)"), "prime"); XCTAssertEqual(try display("isprime(7.0)"), "prime")
        XCTAssertEqual(try display("n = 96 + 1\nisprime(n)"), "prime")
    }
    func testExhaustedFactoringIsAClearFailureThatNeverHidesCompositeness() throws {
        // 2^128 + 1 = 59649589127497217 × 5704689200685129054721 (Morrison and Brillhart); the small factor is beyond the rho budget.
        let failed = try last("factor(2^128+1)")
        XCTAssertNil(failed.value); XCTAssertTrue(failed.error?.contains("exceeded the computation budget") == true, failed.error ?? "nil")
        let composite = try last("isprime(2^128+1)")
        XCTAssertEqual(composite.display, "not prime"); XCTAssertFalse(try XCTUnwrap(composite.value).prime.isPrime)
        XCTAssertTrue(composite.explanation.last?.assumption?.contains("exceeded the budget") == true)
        XCTAssertTrue(try last("factor(15 * (2^128+1))").error?.contains("found 3 × 5") == true)
    }
    func testResultsAreDeterministic() throws {
        XCTAssertEqual(try value("factor(4294967279 * 4294967291)"), try value("factor(4294967279 * 4294967291)"))
        XCTAssertEqual(try value("isprime(2^127-1)"), try value("isprime(2^127-1)"))
    }
    func testAggregatesSkipPrimeLinesWithoutCrashing() throws {
        let results = try SheetEvaluator.evaluate("isprime(7)\nfactor(12)\n5\n6\nsum")
        XCTAssertEqual(results[4].display, "11"); XCTAssertTrue(results[4].explanation.last?.assumption?.contains("prime") == true)
        XCTAssertEqual(try MathSheet.last("isprime(7) #t\nfactor(12) #t\n5 #t\nsum #t").display, "5")
    }
    func testNewNamesLeaveVariablesAndLabelsAlone() throws {
        XCTAssertEqual(try MathSheet.last("factor = 3\nfactor * 2").display, "6")
        XCTAssertEqual(try display("arg = 3\narg"), "3"); XCTAssertEqual(try display("re 4"), "4")
        let plain = try SheetEvaluator.evaluate("factor of safety")[0]; XCTAssertNil(plain.value)
    }
    func testSavedFunctionsParseCanonicalizeAndReload() throws {
        let update = try FunctionUpdate.prepare("check(n) = isprime(n)\nabove(n) = nextprime(n) + 1", .empty, [])
        XCTAssertEqual(update.library.minimumCatalogVersion, FunctionLibrary.latestCatalogVersion)
        let reloaded = try FunctionLibrary(update.library.definitions)
        XCTAssertEqual(update.library.fingerprint, reloaded.fingerprint)
        let results = try SheetEvaluationSession().evaluateWithFunctions("check(91)\nabove(90)", reloaded, []).results
        XCTAssertEqual(results.map(\.display), ["not prime: 7 × 13", "98"])
        MathSheet.throwsFormat { try FunctionLibrary([FunctionDefinition(name: "isprime", parameters: ["n"], body: "n")]) }
        MathSheet.throwsFormat { try FunctionLibrary([FunctionDefinition(name: "bad", parameters: ["n"], body: "factor(n, 2)")]) }
    }
    func testCancellationPropagates() throws {
        let cancelled = CancellationToken(); cancelled.cancel()
        MathSheet.throwsError(.cancelled) { try SheetEvaluator.evaluate("factor(2^128+1)", cancelled) }
    }
}
