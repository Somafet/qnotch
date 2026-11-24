import XCTest
@testable import CalculatorEngine

final class VariableRenameTests: XCTestCase {
    func testRenamesDefinitionsAndReferencesButNotCommentsQuotesTagsOrHeadings() throws {
        let source = "# rate\nrate = 5% // rate\n\"rate\" 100 + rate #rate\nrates = 2\nrate * rates\nRATE"
        XCTAssertEqual(try VariableRename.apply(source, "rate", "fee"), "# rate\nfee = 5% // rate\n\"rate\" 100 + fee #rate\nrates = 2\nfee * rates\nfee")
    }
    func testMultiWordNamesMatchGreedilyAndAcrossSpacing() throws {
        let source = "rent = 10\nmonthly rent = 1200\nmonthly  rent * 12 + rent"
        XCTAssertEqual(try VariableRename.apply(source, "monthly rent", "housing"), "rent = 10\nhousing = 1200\nhousing * 12 + rent")
        XCTAssertEqual(try VariableRename.apply(source, "rent", "cost"), "cost = 10\nmonthly rent = 1200\nmonthly  rent * 12 + cost")
    }
    func testFindsTheVariableAtTheCaretOrExactSelection() throws {
        let source = "a = 1\nmonthly rent = 2\nmonthly rent + a2 + 3a"
        let line = source.netLastIndexOf("\n") + 1
        XCTAssertEqual(try VariableRename.find(source, line + 3, 0)?.name, "monthly rent")
        XCTAssertEqual(try VariableRename.find(source, line + 12, 0)?.name, "monthly rent")
        XCTAssertEqual(try VariableRename.find(source, line, 13)?.name, "monthly rent")
        XCTAssertNil(try VariableRename.find(source, line, 7))
        XCTAssertNil(try VariableRename.find(source, source.netIndexOf("a2"), 0))
        XCTAssertEqual(try VariableRename.find(source, source.netLength, 0)?.name, "a")
        XCTAssertEqual(try VariableRename.find(source, 0, 0)?.span, SourceSpan(0, 1))
        XCTAssertNil(try VariableRename.find("1 + 2", 0, 0))
    }
    func testRejectsInvalidReservedAndTakenNamesButAllowsCaseChanges() throws {
        let source = "a = 1\nb = 2\na + b"
        XCTAssertEqual(try VariableRename.check(source, "a", "B"), .taken)
        XCTAssertEqual(try VariableRename.check(source, "a", "1x"), .invalid)
        XCTAssertEqual(try VariableRename.check(source, "a", "sum"), .invalid)
        XCTAssertEqual(try VariableRename.check(source, "a", "L2"), .invalid)
        XCTAssertEqual(try VariableRename.check(source, "a", " "), .invalid)
        XCTAssertEqual(try VariableRename.apply(source, "a", "A"), "A = 1\nb = 2\nA + b")
        XCTAssertEqual(try VariableRename.apply(source, "a", "  total   cost "), "total cost = 1\nb = 2\ntotal cost + b")
        XCTAssertNil(try VariableRename.apply(source, "a", "b"))
    }
    func testFunctionParametersAreLeftAlone() throws {
        XCTAssertEqual(try VariableRename.apply("x = 3\ntwice(x) = x * 2\ntwice(x)", "x", "y"), "y = 3\ntwice(x) = x * 2\ntwice(y)")
    }
    func testRenamedSheetEvaluatesTheSame() throws {
        let source = "price = 40\ntax rate = 25%\nprice + tax rate\r\nprice * 2"
        let renamed = try XCTUnwrap(try VariableRename.apply(source, "price", "net price"))
        XCTAssertEqual(renamed, "net price = 40\ntax rate = 25%\nnet price + tax rate\r\nnet price * 2")
        XCTAssertEqual(try SheetEvaluationSession().evaluate(source).map(\.display), try SheetEvaluationSession().evaluate(renamed).map(\.display))
    }
}
