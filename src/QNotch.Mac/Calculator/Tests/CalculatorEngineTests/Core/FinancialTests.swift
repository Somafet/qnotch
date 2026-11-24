import XCTest
@testable import CalculatorEngine

/// Fixed-point decimals with 30 fractional digits: the independent recurrences C# runs in System.Decimal
/// (28–29 significant digits). Exact rationals would exceed 4096 bits over 600 compounding periods.
private struct Fixed: Comparable {
    static let scale = BigInt.pow(10, 30)
    let raw: BigInt
    init(raw: BigInt) { self.raw = raw }
    init(_ value: Int) { raw = BigInt(value) * Fixed.scale }
    init(_ value: Rational) { raw = value.numerator * Fixed.scale / value.denominator }
    static func + (a: Fixed, b: Fixed) -> Fixed { Fixed(raw: a.raw + b.raw) }
    static func - (a: Fixed, b: Fixed) -> Fixed { Fixed(raw: a.raw - b.raw) }
    static func * (a: Fixed, b: Fixed) -> Fixed { Fixed(raw: a.raw * b.raw / Fixed.scale) }
    static func < (a: Fixed, b: Fixed) -> Bool { a.raw < b.raw }
    static func parse(_ text: String) throws -> Fixed { Fixed(try Rational.parse(text)) }
}

final class FinancialTests: XCTestCase {
    private func last(_ source: String, _ context: EvaluationContext? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> LineResult {
        let answer = try SheetEvaluator.evaluate(source, context: context).last!
        XCTAssertNil(answer.error, source, file: file, line: line); return answer
    }
    private func magnitude(_ value: SheetValue) throws -> Rational { value.kind == .money ? try value.money.magnitude.scalar : try value.scalar }
    /// C# Decimal(value): the magnitude truncated to 16 decimal places.
    private func decimal(_ value: SheetValue) throws -> Rational {
        let r = try magnitude(value); return try Rational(r.numerator * BigInt.pow(10, 16) / r.denominator, BigInt.pow(10, 16))
    }
    private func inRange(_ value: Rational, _ low: String, _ high: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try value >= Rational.parse(low) && value <= Rational.parse(high), "\(value) not in \(low)…\(high) \(message)", file: file, line: line)
    }
    private func inRange(_ value: Fixed, _ low: String, _ high: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try value >= Fixed.parse(low) && value <= Fixed.parse(high), "\(value.raw) not in \(low)…\(high) \(message)", file: file, line: line)
    }
    private func schedule(_ result: LineResult, file: StaticString = #filePath, line: UInt = #line) -> [AmortizationYear] {
        let steps = result.explanation.filter { ($0.schedule?.count ?? 0) > 0 }
        XCTAssertEqual(steps.count, 1, file: file, line: line)
        return steps.first?.schedule ?? []
    }

    func testPublicAndBoundaryExamples() throws {
        try theory([
            ("loan 200k at 5% for 30 years", "1073.6432"),
            ("mortgage 300k with 20% down at 5% for 30 years", "1288.3719"),
            ("loan 2400 with 1200 down at 0% for 12 months", "100"),
            ("mortgage 300k with 100% down at 0% for 30 years", "0"),
            ("10k at 4% for 5 years", "12166.529"),
            ("5000 at 7% for 3 years compounded monthly", "6164.6279"),
            ("save 500/month at 7% for 20 years", "260463.3299"),
            ("save 100 per year at 5% for 2 years", "205"),
            ("save 100 monthly at 0% for 1.5 years", "1800"),
            ("1000 at -10% for 2 years", "810"),
            ("pmt(5%/12,360,200000)", "1073.6432"),
            ("pmt(0,12,1200)", "100"),
            ("pmt(0,12,-1200)", "-100"),
            ("pmt(0,12,1200,-600,1)", "50"),
            ("fv(10%,2,-100,-1000)", "1420"),
            ("fv(10%,2,-100,-1000,1)", "1441"),
            ("pv(10%,2,-100,0)", "173.5537"),
            ("fv(0,0,100,-1000)", "1000"),
            ("pv(0,0,100,-1000)", "1000"),
            ("npv(10%,100,200,300)", "481.5928"),
            ("npv(0,-100,200,-300)", "-200"),
            ("loan 1200 EUR at 0% for 1 year", "100 EUR"),
            ("save $100/month at 0% for 1 year", "1200 USD"),
            ("pmt(0,12,1200 USD,0)", "100 USD"),
            ("fv(0,12,-100 EUR,0)", "1200 EUR"),
            ("p=loan 1200 at 0% for 1 year\np*12", "1200"),
            ("f(p)=loan p at 0% for 1 year\nf(1200)", "100"),
            ("f(r,n,p)=pmt(r,n,p)\nf(0,12,1200)", "100"),
            ("fv(0,2,-(save 100/year at 0% for 1 year))", "200"),
        ]) { source, expected in XCTAssertEqual(try last(source).display, expected, source) }
    }
    func testPaymentTimingAndSignsUseExplicitEquations() throws {
        let end = try last("pmt(10%,2,1000)").value!.scalar
        let begin = try last("pmt(10%,2,1000,0,1)").value!.scalar
        XCTAssertEqual(try end / Rational(11, 10), begin)
        let result = try last("payment=pmt(10%,2,1000)\nfv(10%,2,-payment,1000)")
        XCTAssertEqual(try result.value!.scalar, Rational.zero)
        XCTAssertTrue(try last("pmt(0,12,1200)").explanation.contains { $0.assumption?.contains("opposite Excel PMT sign") == true })
    }
    func testDisplayRoundingDoesNotChangeAuthoritativePayments() throws {
        let answer = try last("p=pmt(0,3,100)\np*3")
        XCTAssertEqual(try answer.value!.scalar, Rational(100))
        XCTAssertEqual(try last("pmt(0,3,100)").value!.scalar, try Rational(100, 3))
        XCTAssertEqual(try last("pmt(0,3,100) to 6 decimals").display, "33.333333")
    }
    func testHighPrecisionFallbackCoversOrdinaryMortgageRatesAndKeepsItsMarker() throws {
        let loan = try last("loan 250000 at 4.99% for 30 years")
        XCTAssertTrue(try loan.value!.number.isApproximate)
        XCTAssertTrue(loan.display.hasPrefix("≈ "))
        // Independently evaluated with Python decimal at 60 digits, not the Core annuity implementation.
        try inRange(try decimal(loan.value!), "1340.5265795946524663", "1340.5265795946524664")
        for tail in ["x*2", "x+1", "abs(x)", "x to 2 decimals", "average", "x USD", "npv(0,x)", "fv(0,1,-x)", "share(x,x)"] {
            XCTAssertTrue(try last("x=loan 250000 at 4.99% for 30 years\n" + tail).display.hasPrefix("≈ "), tail)
        }
        XCTAssertTrue(loan.explanation.contains { $0.assumption?.contains("34 significant digits") == true })
        XCTAssertFalse(try last("loan 1200 at 0% for 1 year").value!.number.isApproximate)
    }
    func testPublishedSpreadsheetCasesUseIndependentRoundedExpectations() throws {
        XCTAssertEqual(try last("pmt(8%/12,10,10000)").display, "1037.0321")
        XCTAssertEqual(try last("pmt(8%/12,10,10000,0,1)").display, "1030.1643")
        try inRange(try decimal(try last("fv(6%/12,120,-200,-500)").value!), "33685.5677283086858785", "33685.5677283086858786")
    }
    func testAmortizationRowsConservePrincipalInterestAndFinalBalance() throws {
        let answer = try last("amortize 200k at 5% for 30 years")
        let rows = schedule(answer)
        XCTAssertEqual(rows.count, 30)
        for row in rows { XCTAssertEqual(row.payments, 12) }
        let principal = try rows.reduce(Rational.zero) { try $0 + decimal($1.principal) }
        let interest = try rows.reduce(Rational.zero) { try $0 + decimal($1.interest) }
        try inRange(principal, "199999.99999999", "200000.00000001")
        try inRange(interest, "186511.568568", "186511.568570")
        XCTAssertEqual(try magnitude(rows[rows.count - 1].balance), Rational.zero)
        XCTAssertTrue(answer.explanation.contains { $0.assumption?.contains("display rounding is not payment settlement") == true })
    }
    func testPartialYearsZeroNegativeRatesAndMaximumScheduleAreBounded() throws {
        let partial = schedule(try last("amortize 3000 at 0% for 30 months"))
        XCTAssertEqual(partial.map(\.payments), [12, 12, 6])
        XCTAssertEqual(try magnitude(partial[1].balance), Rational(600))
        let negative = schedule(try last("amortize 3000 at -5% for 2 years"))
        for row in negative { XCTAssertTrue(try magnitude(row.interest).sign < 0) }
        XCTAssertEqual(schedule(try last("amortize 120000 at 0% for 100 years")).count, 100)
        XCTAssertEqual(try magnitude(negative[negative.count - 1].balance), Rational.zero)
    }
    func testSeededCashFlowRecurrencesVerifyAnnuitiesAndSchedules() throws {
        var random = NetRandom(43019)
        for _ in 0..<150 {
            let principal = random.next(1, 100000); let basisPoints = random.next(-500, 2001); let n = random.next(1, 61)
            let rateText = try Rational(basisPoints, 100).description
            let rate = Fixed(try Rational(basisPoints, 120000))
            let payment = try last("pmt(\(rateText)%/12,\(n),\(principal))").value!
            var balance = Fixed(principal)
            for _ in 0..<n { balance = balance * (Fixed(1) + rate) - Fixed(try decimal(payment)) }
            try inRange(balance, "-0.00000001", "0.00000001")
            let pmt = random.next(1, 1000); var future = Fixed(principal)
            for _ in 0..<n { future = future * (Fixed(1) + rate) + Fixed(pmt) }
            let actual = Fixed(try decimal(try last("fv(\(rateText)%/12,\(n),-\(pmt),-\(principal))").value!))
            try inRange(actual - future, "-0.00000001", "0.00000001")
        }
    }
    func testLongTermsAndFallbackSchedulesAgreeWithIndependentDecimalRecurrences() throws {
        var random = NetRandom(77092)
        for _ in 0..<60 {
            let principal = random.next(1000, 300000); let basisPoints = random.next(-900, 1900); let n = random.next(180, 601)
            let rate = Fixed(try Rational(basisPoints, 120000))
            let rateText = try Rational(basisPoints, 100).description
            let answer = try last("amortize \(principal) at \(rateText)% for \(n) months")
            let payment = Fixed(try decimal(answer.value!)); var balance = Fixed(principal)
            let rows = schedule(answer)
            var rowIndex = 0; var rowInterest = Fixed(0), rowPrincipal = Fixed(0)
            for period in 1...n {
                let interest = balance * rate; rowInterest = rowInterest + interest; rowPrincipal = rowPrincipal + payment - interest
                balance = balance + interest - payment
                if period % 12 != 0 && period != n { continue }
                let row = rows[rowIndex]; rowIndex += 1
                try inRange(Fixed(try decimal(row.interest)) - rowInterest, "-0.00000001", "0.00000001")
                try inRange(Fixed(try decimal(row.principal)) - rowPrincipal, "-0.00000001", "0.00000001")
                try inRange(Fixed(try decimal(row.balance)) - balance, "-0.00000001", "0.00000001")
                rowInterest = Fixed(0); rowPrincipal = Fixed(0)
            }
            try inRange(balance, "-0.00000001", "0.00000001")
        }
    }
    func testApproximateAmountsCannotSilentlyBecomeExactCountsOrTimestamps() throws {
        try theory(["x!", "(x) months", "(x) working days", "unix x", "15:00 + x h"]) { tail in
            XCTAssertNotNil(try SheetEvaluator.evaluate("x=(loan 250000 at 4.99% for 30 years) to 0 decimals\n" + tail).last!.error, tail)
        }
    }
    func testCurrencyCashFlowsConvertOnlyWhenNeededAndKeepProvenance() throws {
        let snapshot = try CurrencyRateSnapshot(provider: "Fixture", baseCurrency: "EUR", asOf: DateOnly(2026, 10, 30)!, retrievedAt: .utc(2026, 10, 31), rates: [("EUR", .one), ("USD", Rational(2))])
        let context = EvaluationContext(today: DateOnly(2026, 10, 31), currencyRates: try CurrencyRateBook(snapshot, []))
        let answer = try last("npv(0,10 EUR,20 USD)", context)
        XCTAssertEqual(answer.display, "20 EUR"); XCTAssertEqual(try answer.value!.money.rateSnapshotKey, snapshot.key)
        XCTAssertTrue(answer.explanation.contains { $0.assumption?.contains("Fixture") == true })
        let session = SheetEvaluationSession()
        let result = try session.evaluateWithFunctions("loan 1200 EUR at 0% for 1 year\n2+2", .empty, [])
        XCTAssertFalse(result.usesCurrencyRates); XCTAssertFalse(result.usesCurrentDate); XCTAssertFalse(result.usesCurrentInstant)
    }
    func testDependenciesAndFunctionsRefreshWithoutReparsingUnchangedLines() throws {
        let session = SheetEvaluationSession()
        let source = "principal=1200\nf(p)=pmt(0,12,p)\nf(principal)\n7"
        _ = try session.evaluateWithFunctions(source, .empty, [])
        let second = try session.evaluateWithFunctions(source.replacingOccurrences(of: "1200", with: "2400"), .empty, [])
        XCTAssertEqual(second.results[2].display, "200")
        XCTAssertEqual(session.lastStatistics.parsedLines, 1); XCTAssertTrue(session.lastStatistics.reusedResults >= 1)
    }
    func testInvalidInputsNeverPublishPlausibleResults() throws {
        try theory([
            "loan -100 at 5% for 1 year", "mortgage 100 with 101% down at 5% for 1 year", "loan 100 with -1 down at 0% for 1 year", "loan 100 at -100% for 1 year",
            "100 at 5% for 1.5 years", "loan 100 at 5% for 0 years", "loan 100 at 5% for 1201 months", "loan 100 at 5% for 365 days", "save 100 at 5% for 1 year",
            "save 100/month at 5% for 1 year compounded annually", "pmt(5%,0,100)", "pmt(5%,1.5,100)", "pmt(5%,12,100,0,2)", "pmt(5%,12,100,0,0,1)", "pmt(5%,12)",
            "pmt(sqrt(2),12,100)", "pmt(0,12,100 kg)", "pv(-100%,12,100)", "npv(10%)", "npv(-100%,100)", "npv(0,100 USD,100)",
            "loan 100 USD with 10 down at 0% for 1 year", "loan 100 USD/h at 5% for 1 year", "f(x)=pmt(x)\nf(1)",
        ]) { source in XCTAssertNotNil(try SheetEvaluator.evaluate(source).last!.error, source) }
    }
    func testCancellationAndSharedBudgetsRemainActive() throws {
        let cancel = CancellationToken(); cancel.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("amortize 10000 at 5% for 30 years", cancel)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        let source = Array(repeating: "amortize 1000 at 5% for 100 years", count: 200).joined(separator: "\n")
        XCTAssertThrowsError(try SheetEvaluator.evaluate(source)) { XCTAssertEqual($0 as? CalcError, .computationLimit) }
    }
}
