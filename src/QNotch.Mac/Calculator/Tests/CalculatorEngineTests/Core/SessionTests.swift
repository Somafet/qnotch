import XCTest
@testable import CalculatorEngine

final class SessionTests: XCTestCase {
    private func rows(_ results: [LineResult]) -> [String] { results.map { "\($0.display)|\($0.value.map { "\($0)" } ?? "nil")|\($0.error ?? "nil")" } }
    func testOnlyChangedLineAndDependentsReevaluate() throws {
        let session = SheetEvaluationSession()
        _ = try session.evaluate("a=2\na+1\n40+2")
        let result = try session.evaluate("a=3\na+1\n40+2")
        XCTAssertEqual(result[1].display, "4")
        XCTAssertEqual(session.lastStatistics, EvaluationStatistics(parsedLines: 1, evaluatedLines: 2, reusedResults: 1))
        _ = try session.evaluate("a=3\na+1\n40+2")
        XCTAssertEqual(session.lastStatistics, EvaluationStatistics(parsedLines: 0, evaluatedLines: 0, reusedResults: 3))
    }
    func testBindingChangesInvalidateEvenWhenDependencySetIsUnchanged() throws {
        let session = SheetEvaluationSession()
        XCTAssertEqual(try session.evaluate("a=1\nb=2\na-b")[2].display, "-1")
        XCTAssertEqual(try session.evaluate("b=1\na=2\na-b")[2].display, "1")
        _ = try session.evaluate("label 10\n3")
        XCTAssertNotNil(try session.evaluate("label 10\nlabel=3")[0].error)
    }
    func testInsertionTagsCyclesAndFailureTransitionsMatchFreshEvaluation() throws {
        let session = SheetEvaluationSession()
        for source in ["1 #x\n2\nsum #x", "# heading\n1 #x\n2 #x\nsum #x", "a=L2\na", "a=1/0\na", "a=2\na", "hello\nhello+1", "hello=3\nhello+1"] {
            let actual = try session.evaluate(source), fresh = try SheetEvaluator.evaluate(source)
            XCTAssertEqual(rows(actual), rows(fresh), source)
            XCTAssertEqual(actual.map { $0.value }, fresh.map { $0.value }, source)
            for i in actual.indices { XCTAssertEqual(actual[i].dependencies, fresh[i].dependencies) }
        }
    }
    func testRandomEditsMatchStatelessEvaluation() throws {
        var random = NetRandom(881)
        let session = SheetEvaluationSession()
        var lines = ["a=2", "b=3", "a-b", "10 #cost", "sum #cost"]
        let choices = ["a=4", "b=7", "a=1/0", "a-b", "a = L3", "b = a+1", "note", "cost 12 #cost", "sum #cost", "average", "# Heading", "", "50 is what % of 200"]
        for _ in 0..<200 {
            let index = random.next(lines.count)
            if random.next(4) == 0 && lines.count < 30 { lines.insert(choices[random.next(choices.count)], at: index) }
            else { lines[index] = choices[random.next(choices.count)] }
            let source = lines.joined(separator: "\n")
            let actual = try session.evaluate(source), expected = try SheetEvaluator.evaluate(source)
            XCTAssertEqual(rows(actual), rows(expected), source)
            XCTAssertEqual(actual.map { $0.value }, expected.map { $0.value }, source)
        }
    }
    func testCancelledRevisionDoesNotReplaceSnapshot() throws {
        let session = SheetEvaluationSession(); _ = try session.evaluate("a=2\na+1")
        let cancelled = CancellationToken(); cancelled.cancel()
        XCTAssertThrowsError(try session.evaluate("a=5\na+1", cancelled)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        XCTAssertEqual(try session.evaluate("a=2\na+1")[1].display, "3")
        XCTAssertEqual(session.lastStatistics.reusedResults, 2)
    }
    func testRemovingADeclarationDoesNotReuseItsPreviousParseError() throws {
        let session = SheetEvaluationSession()
        XCTAssertEqual(try session.evaluate("Label 10\nnotes")[0].display, "10")
        XCTAssertNotNil(try session.evaluate("Label 10\nLabel=3")[0].error)
        XCTAssertEqual(try session.evaluate("Label 10\nnotes")[0].display, "10")
    }
}
