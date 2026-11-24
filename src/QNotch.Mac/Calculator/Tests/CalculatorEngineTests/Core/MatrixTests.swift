import XCTest
@testable import CalculatorEngine

final class MatrixTests: XCTestCase {
    private func last(_ source: String) throws -> LineResult { try MathSheet.last(source) }

    func testIndependentPermutationAndCofactorOracle() throws {
        let cases = try JSONNode.parse(Fixtures.data("matrices-v1.json")).property("cases").arrayItems()
        XCTAssertEqual(cases.count, 471)
        try theory(cases) { item in
            let source = try item.property("source").string()
            let value = try MathSheet.value(source)
            let expected = try item.property("values").arrayItems().map { try $0.arrayItems().map { try MathSheet.fraction($0.string()) } }
            switch try item.property("kind").string() {
            case "number": XCTAssertEqual(value.kind, .number, source); XCTAssertEqual(try value.scalar, expected[0][0], source)
            case "list": XCTAssertEqual(value.kind, .list, source); XCTAssertEqual(try value.list.values.map { try $0.scalar }, expected[0], source)
            default:
                XCTAssertEqual(value.kind, .matrix, source)
                let matrix = try value.matrix
                XCTAssertEqual(matrix.rowCount, expected.count, source); XCTAssertEqual(matrix.columnCount, expected[0].count, source)
                for r in 0..<expected.count { for c in 0..<expected[r].count { XCTAssertEqual(try matrix[r, c].scalar, expected[r][c], source) } }
            }
        }
    }
    func testPublishedExamplesAndTypedCompositions() throws {
        try theory([
            ("det([[1,2],[3,4]])", "-2"), ("inverse([[1,2],[3,4]])", "[[-2, 1], [1.5, -0.5]]"), ("[[1,2],[3,4]]*[[5],[6]]", "[[17], [39]]"),
            ("dot([1,2,3],[4,5,6])", "32"), ("cross([1,0,0],[0,1,0])", "[0, 0, 1]"), ("norm([3,4])", "5"), ("norm([1,1])", "sqrt(2)"),
            ("transpose([[1,2,3],[4,5,6]])", "[[1, 4], [2, 5], [3, 6]]"), ("trace([[1,2],[3,4]])", "5"), ("[[0,1],[2,3]]*[5,6]", "[6, 28]"),
            ("[5,6]*[[0,1],[2,3]]", "[12, 23]"), ("[[1,2]]+[[3,4]]", "[[4, 6]]"), ("[1,2]-[3,4]", "[-2, -2]"), ("-[1,2]*2", "[-2, -4]"),
            ("2*[[1,2]]", "[[2, 4]]"), ("[[1,2]]/2", "[[0.5, 1]]"), ("[[1,2]]*20%", "[[0.2, 0.4]]"), ("inverse([[3]]) to 3 decimals", "[[0.333]]"),
            ("[1/3,2/3] to 2 decimals", "[0.33, 0.67]"), ("det([[0,1],[1,0]])", "-1"), ("det([[1,2],[2,4]])", "0"), ("inv([[2]])", "[[0.5]]"),
            ("determinant([[2]])", "2"), ("det([[sqrt(2),1],[1,sqrt(2)]])", "1"), ("x=[[sqrt(2),1],[1,sqrt(2)]]\nx*inverse(x)", "[[1, 0], [0, 1]]"),
            ("4\n5\n[[1,2],[3,4]]\n[1,2]\nsum", "9"), ("f(x)=det(x)\nf([[1,2],[3,4]])", "-2"), ("f(x,y)=[[x,1],[1,y]]\ntrace(f(2,3))", "5"),
        ]) { source, expected in XCTAssertEqual(try last(source).display, expected, source) }
    }
    func testInvalidShapesTypesAndDomainsAreExplicit() throws {
        try theory([
            "[[]]", "[[1],[2,3]]", "[[1],2]", "[[[1]]]", "[[1 USD]]", "[[today]]", "[[1%,2%]]", "[[1 m,2 s]]", "[[0 °C]]", "det([1,2])", "det([[1,2]])",
            "inverse([[1,2],[2,4]])", "inverse([[0]])", "trace([[1,2]])", "norm([])", "norm([1 USD])", "dot([1,2],[3])", "cross([1,2],[3,4])",
            "dot([1 m,2 s],[3,4])", "[1,2]*[3,4]", "[[1,2]]*[[3,4]]", "[[1,2]]+[1,2]", "[[1,2]]+[[1],[2]]", "[[1]]+1", "1/[[1]]", "[[1]]/0",
            "[[1]]^2", "[[1]]!", "[[1]]%", "sum([[1,2]])", "transpose()", "dot([1],[1],[1])", "norm([1%])",
        ]) { source in XCTAssertNotNil(try MathSheet.line(source).error, source) }
    }
    func testUnitsUseCanonicalMagnitudesWithoutLosingTheDisplayBasis() throws {
        let det = try XCTUnwrap(try last("det([[1 m,200 cm],[3 m,400 cm]])").value).number
        XCTAssertEqual(try det.exact.rational, Rational(-2)); XCTAssertEqual(det.unit!.dimension, Dimension(2, 0, 0, 0, 0, 0, 0, 0))
        let inv = try XCTUnwrap(try last("inverse([[2 cm]])").value).matrix[0, 0]
        XCTAssertEqual(try inv.exact.rational, Rational(50)); XCTAssertEqual(inv.unit!.factor, Rational(100))
        XCTAssertEqual(try last("norm([300 cm,4 m]) in m").display, "5 m")
        XCTAssertEqual(try last("dot([1 m,2 m],[3 m,4 m])").display, "11 m^2")
        let identity = try XCTUnwrap(try last("a=[[1 m,2 m],[3 m,4 m]]\na*inverse(a)").value).matrix
        XCTAssertNil(identity[0, 0].unit); XCTAssertEqual(try identity[0, 0].scalar, Rational(1))
    }
    func testImmutableMatricesCompareByCellsAndKeepCompleteCopies() throws {
        let row = try SheetList([SheetValue(Rational(1)), SheetValue(Rational(2))])
        var input = [row]; let matrix = try SheetMatrix(input); input[0] = try SheetList([SheetValue(Rational(9))])
        XCTAssertEqual(try matrix[0, 1].scalar, Rational(2)); XCTAssertEqual(matrix, try SheetMatrix([row]))
        // C# also checks that Rows is a read-only list; Swift's `let rows: [SheetList]` cannot be mutated through the matrix at all.
        let literal = "[" + Array(repeating: "[" + (100001...100012).map(String.init).joined(separator: ",") + "]", count: 12).joined(separator: ",") + "]"
        let value = try XCTUnwrap(try last(literal).value)
        XCTAssertTrue(try value.display.netLength <= 516); XCTAssertTrue(try value.display.contains("…")); XCTAssertFalse(try value.copyText.contains("…"))
        XCTAssertEqual(try value.copyText.utf16.filter { $0 == 0x2C }.count, 143)
        XCTAssertEqual(try value.matrix, try XCTUnwrap(try last(try value.copyText).value).matrix)
    }
    func testLargeSupportedShapesAndExpressionSheetLimitsAreEnforced() throws {
        func identity(_ n: Int) -> String { MathSheet.matrixLiteral(n, n) { r, c in r == c ? "1" : "0" } }
        let twelve = identity(12); XCTAssertEqual(try last(twelve).value, try last("inverse(" + twelve + ")").value)
        XCTAssertNotNil(try SheetEvaluator.evaluate(identity(13))[0].error)
        let dense = MathSheet.matrixLiteral(12, 12) { r, c in String(r == c ? 20 : 1 + (r + c) % 3) }
        XCTAssertNil(try last("inverse(" + dense + ")").error)
        // Calls share the sheet budget; neither rational arithmetic nor repeated saved calls bypasses it.
        let source = "a=" + dense + "\n" + Array(repeating: "inverse(a)", count: 100).joined(separator: "\n")
        MathSheet.throwsError(.computationLimit) { try SheetEvaluator.evaluate(source) }
        let cancelled = CancellationToken(); cancelled.cancel()
        MathSheet.throwsError(.cancelled) { try SheetEvaluator.evaluate("inverse(" + dense + ")", cancelled) }
    }
    func testCacheDependenciesAndSavedFunctionsKeepMatricesTypedAndStatic() throws {
        let session = SheetEvaluationSession(); let source = "x=1\na=[[x,2],[3,4]]\ndet(a)\n7"
        _ = try session.evaluateWithFunctions(source, .empty, [])
        let changed = try session.evaluateWithFunctions(source.netReplace("x=1", "x=2"), .empty, [])
        XCTAssertEqual(changed.results[2].display, "2"); XCTAssertEqual(session.lastStatistics.parsedLines, 1); XCTAssertEqual(session.lastStatistics.reusedResults, 1)
        let future = try session.evaluateWithFunctions(source.netReplace("x=1", "x=2"), .empty, [], context: EvaluationContext(today: DateOnly(2040, 1, 1), now: MathSheet.utc(2026, 11, 24)))
        XCTAssertEqual(session.lastStatistics.reusedResults, 4); XCTAssertFalse(future.usesCurrentDate); XCTAssertFalse(future.usesCurrentInstant); XCTAssertFalse(future.usesCurrencyRates)
        let library = try FunctionLibrary([FunctionDefinition(name: "linear", parameters: ["a", "v"], body: "a*v"), FunctionDefinition(name: "reverse", parameters: ["a"], body: "inverse(a)")])
        let computed = try session.evaluateWithFunctions("linear(reverse([[1,2],[3,4]]),[5,6])", library, [])
        XCTAssertEqual(computed.results[0].display, "[-4, 4.5]")
        MathSheet.throwsFormat { try FunctionLibrary([FunctionDefinition(name: "norm", parameters: ["x"], body: "x")]) }
        MathSheet.throwsFormat { try FunctionLibrary([FunctionDefinition(name: "wrong", parameters: ["x"], body: "dot(x)")]) }
        for result in try SheetEvaluator.evaluate("a=[[b]]\nb=det(a)") { XCTAssertEqual(result.error, "Circular dependency") }
    }
    func testApproximationProvenanceSurvivesAllOutputs() throws {
        // Existing long-term finance intentionally produces a represented approximation.
        let setup = "x=fv(1%/12,1200,0,1)\na=[[1,x],[0,1]]\n"
        XCTAssertTrue(try XCTUnwrap(try last(setup + "a").value).matrix.isApproximate)
        for operation in ["det(a)", "trace(a)", "norm([1,x*0])", "dot([x,1],[0,1])"] {
            let result = try last(setup + operation)
            XCTAssertTrue(try XCTUnwrap(result.value).number.isApproximate, operation)
            XCTAssertTrue(result.explanation.contains { $0.assumption?.contains("Approximate") == true }, operation)
        }
        XCTAssertTrue(try XCTUnwrap(try last(setup + "inverse(a)").value).matrix.isApproximate)
    }
    func testSeededAlgebraicIdentitiesHoldExactlyInBothMultiplicationOrders() throws {
        var random = NetRandom(80826)
        for trial in 0..<40 {
            let n = 2 + trial % 4
            // Strict diagonal dominance guarantees nonsingularity without consulting Calc's determinant.
            func matrix() -> String { MathSheet.matrixLiteral(n, n) { r, c in String(r == c ? 50 + random.next(10) : random.next(-4, 5)) } }
            let a = matrix(), b = matrix(), setup = "a=" + a + "\nb=" + b + "\n"
            let identity = try XCTUnwrap(try last(setup + "a*inverse(a)").value).matrix
            for r in 0..<n { for c in 0..<n { XCTAssertEqual(try identity[r, c].scalar, Rational(r == c ? 1 : 0)) } }
            XCTAssertEqual(identity, try XCTUnwrap(try last(setup + "inverse(a)*a").value).matrix)
            XCTAssertEqual(try last(setup + "det(a*b)-det(a)*det(b)").display, "0")
            XCTAssertEqual(try last(setup + "det(transpose(a))-det(a)").display, "0")
            XCTAssertEqual(try last(setup + "trace(a+b)-trace(a)-trace(b)").display, "0")
            XCTAssertEqual(try last(setup + "transpose(a*b)").value, try last(setup + "transpose(b)*transpose(a)").value)
            XCTAssertEqual(try last(setup + "inverse(a*b)").value, try last(setup + "inverse(b)*inverse(a)").value)
        }
        for _ in 0..<40 {
            func vector() -> String { "[" + (0..<3).map { _ in String(random.next(-9, 10)) }.joined(separator: ",") + "]" }
            let u = vector(), v = vector(), setup = "u=" + u + "\nv=" + v + "\n"
            XCTAssertEqual(try last(setup + "dot(cross(u,v),u)").display, "0")
            XCTAssertEqual(try last(setup + "dot(cross(u,v),v)").display, "0")
            XCTAssertEqual(try last(setup + "cross(u,v)").value, try last(setup + "-cross(v,u)").value)
            XCTAssertEqual(try last(setup + "norm(cross(u,v))^2-dot(u,u)*dot(v,v)+dot(u,v)^2").display, "0")
        }
    }
    func testInverseDoesNotComputeAnUnneededOverflowingDeterminant() throws {
        let diagonal = MathSheet.matrixLiteral(8, 8) { r, c in r == c ? "10^200" : "0" }
        let inverse = try XCTUnwrap(try last("inverse(" + diagonal + ")").value).matrix
        XCTAssertEqual(try inverse[0, 0].scalar, try Rational(.one, BigInt.pow(10, 200)))
        XCTAssertNotNil(try SheetEvaluator.evaluate("det(" + diagonal + ")")[0].error)
    }
}
