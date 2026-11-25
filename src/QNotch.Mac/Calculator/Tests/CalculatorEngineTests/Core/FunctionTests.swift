import XCTest
@testable import CalculatorEngine

final class FunctionTests: XCTestCase {
    func testConstantsArityAndLibraryLimits() throws {
        XCTAssertEqual(try SheetEvaluator.evaluate("constant()=7\nconstant()")[1].display, "7")
        let wrong = try SheetEvaluator.evaluate("f(x)=x+1\nf(1,2)")[1]
        XCTAssertNil(wrong.value); XCTAssertEqual(wrong.error, "f expects 1 argument(s)")
        XCTAssertThrowsError(try FunctionLibrary((0..<129).map { FunctionDefinition(name: "f\($0)", parameters: ["x"], body: "x+1") })) { XCTAssertTrue(($0 as? CalcError)?.isArithmetic == true) }
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "f", parameters: (0..<17).map { "x\($0)" }, body: "1")])) { XCTAssertTrue(($0 as? CalcError)?.isFormat == true) }
        let result = try SheetEvaluator.evaluate("f(x)=x+1\nf(2)")[1]
        XCTAssertTrue(result.explanation.contains { $0.assumption == "f(x) = x+1" })
    }
    func testDefinitionCallsForwardAndMultipleArguments() throws {
        let values = try SheetEvaluator.evaluate("f(100)\nf(x) = x * 1.19\narea(w,h)=w*h\narea(3,4)")
        XCTAssertEqual(values[0].display, "119"); XCTAssertEqual(values[1].display, ""); XCTAssertEqual(values[3].display, "12")
    }
    func testParametersAreLocalTypedAndNested() throws {
        let values = try SheetEvaluator.evaluate("x=999\ntip(x,p)=x+p\ntwice(x)=tip(x,10%)*2\ntwice(100)\ntip(100,20%)")
        XCTAssertEqual(values[3].display, "220"); XCTAssertEqual(values[4].display, "120")
        XCTAssertTrue(values[3].dependencies.isEmpty)
    }
    func testExpandedNestedExplanationsRemainBoundedAndIncludeTheCallDefinition() throws {
        let body = "x" + String(repeating: "+1", count: 100)
        let answer = try SheetEvaluator.evaluate("f(x)=\(body)\ng(x)=f(x)+f(x)\ng(1)")[2]
        XCTAssertNil(answer.error); XCTAssertEqual(answer.display, "202")
        XCTAssertTrue((1...64).contains(answer.explanation.count))
        XCTAssertTrue(answer.explanation.contains { $0.assumption == "g(x) = f(x)+f(x)" })
        XCTAssertTrue(answer.explanation.contains { $0.assumption?.contains("limited") == true })
    }
    func testInvalidScopeOrRecursionHasNoNumericResult() throws {
        try theory(["f(x)=x+y\nf(2)", "f(x)=prev+1\nf(2)", "f(x)=f(x)\nf(2)", "f(x)=g(x)\ng(x)=f(x)\nf(2)", "sqrt(x)=x\nsqrt(2)", "abs(x)=x\nabs(-2)",
                    "f(x,x)=x\nf(2,3)", "f(x)=unknown(x)\nf(2)"]) { source in
            let values = try SheetEvaluator.evaluate(source)
            XCTAssertNotNil(values[0].error, source); XCTAssertNil(values.last!.value, source)
        }
    }
    func testDefinitionAndForgetPersistOnlyOncePerReceipt() throws {
        let define = try FunctionUpdate.prepare("f(x)=x+1", .empty, [])
        let other = try FunctionUpdate.prepare("f(x)=x+2", define.library, [])
        let oldSheet = try SheetEvaluationSession().evaluateWithFunctions("f(x)=x+1\nf(10)", other.library, define.receipts)
        XCTAssertEqual(oldSheet.results[1].display, "12")
        let forget = try FunctionUpdate.prepare("forget f", other.library, [])
        XCTAssertTrue(forget.library.definitions.isEmpty)
        let recreate = try FunctionUpdate.prepare("f(x)=x+3", forget.library, [])
        let forgottenSheet = try SheetEvaluationSession().evaluateWithFunctions("forget f\nf(10)", recreate.library, forget.receipts)
        XCTAssertEqual(forgottenSheet.results[1].display, "13")
        XCTAssertFalse(try FunctionUpdate.prepare("forget f", recreate.library, forget.receipts).hasChanges)
    }
    func testRemovalOfSourceDoesNotForgetAndReaddingIsAnAction() throws {
        let created = try FunctionUpdate.prepare("f(x)=x+1", .empty, [])
        let removed = try FunctionUpdate.prepare("notes", created.library, created.receipts)
        XCTAssertEqual(removed.library.definitions.count, 1); XCTAssertTrue(removed.receipts.isEmpty)
        let changedElsewhere = try FunctionUpdate.prepare("f(x)=x+2", removed.library, [])
        let readded = try FunctionUpdate.prepare("f(x)=x+1", changedElsewhere.library, removed.receipts)
        XCTAssertTrue(readded.hasChanges)
        XCTAssertEqual(try SheetEvaluationSession().evaluateWithFunctions("f(10)", readded.library, []).results[0].display, "11")
    }
    func testInvalidDraftRetainsCommittedLibraryButBlocksStaleCalls() throws {
        let good = try FunctionUpdate.prepare("f(x)=x+1", .empty, [])
        let session = SheetEvaluationSession()
        let bad = try session.evaluateWithFunctions("f(x)=typo\nf(10)", good.library, good.receipts)
        XCTAssertEqual(bad.functions.library.fingerprint, good.library.fingerprint)
        XCTAssertNotNil(bad.results[0].error); XCTAssertNil(bad.results[1].value)
        let fixedDraft = try session.evaluateWithFunctions("f(x)=x+2\nf(10)", good.library, good.receipts)
        XCTAssertNil(fixedDraft.results[0].error); XCTAssertEqual(fixedDraft.results[1].display, "12")
        let committed = try session.evaluateWithFunctions("f(x)=x+2\nf(10)", fixedDraft.functions.library, fixedDraft.functions.receipts)
        XCTAssertNil(committed.results[0].error); XCTAssertEqual(committed.results[1].display, "12")
    }
    func testLibraryChangesInvalidateCallersEvenWithUnchangedSheet() throws {
        let a = try FunctionLibrary([FunctionDefinition(name: "f", parameters: ["x"], body: "x+1")])
        let b = try FunctionLibrary([FunctionDefinition(name: "f", parameters: ["x"], body: "x+2")])
        let session = SheetEvaluationSession()
        XCTAssertEqual(try session.evaluateWithFunctions("f(10)", a, []).results[0].display, "11")
        XCTAssertEqual(try session.evaluateWithFunctions("f(10)", b, []).results[0].display, "12")
    }
    func testAcyclicExpansionStillHasASharedStepBudget() throws {
        let library = try FunctionLibrary((0..<20).map { FunctionDefinition(name: "f\($0)", parameters: ["x"], body: $0 == 0 ? "x+x" : "f\($0 - 1)(x)+f\($0 - 1)(x)") })
        XCTAssertEqual(try SheetEvaluationSession().evaluateWithFunctions("f19(1)", library, []).results[0].error, "Expression step limit exceeded")
    }
    func testRepeatedFunctionExpansionHasAWholeSheetBudget() throws {
        let library = try FunctionLibrary((0..<10).map { FunctionDefinition(name: "f\($0)", parameters: ["x"], body: $0 == 0 ? "x+x" : "f\($0 - 1)(x)+f\($0 - 1)(x)") })
        let session = SheetEvaluationSession()
        XCTAssertThrowsError(try session.evaluateWithFunctions(Array(repeating: "f9(1)", count: 100).joined(separator: "\n"), library, [])) { XCTAssertEqual($0 as? CalcError, .computationLimit) }
        XCTAssertEqual(try session.evaluate("1+1")[0].display, "2")
    }
    func testReceiptsAndLibraryInputsAreBoundedAndCopied() throws {
        var parameters = ["x"]
        let library = try FunctionLibrary([FunctionDefinition(name: "f", parameters: parameters, body: "x+1")]); parameters[0] = "bad"
        XCTAssertEqual(try SheetEvaluationSession().evaluateWithFunctions("f(10)", library, []).results[0].display, "11")
        XCTAssertThrowsError(try FunctionUpdate.validateReceipts([FunctionReceipt(key: "not-a-hash", count: 1)])) { XCTAssertTrue(($0 as? CalcError)?.isFormat == true) }
        XCTAssertTrue(try SheetEvaluator.evaluate(Array(repeating: "forget f", count: 257).joined(separator: "\n")).contains { $0.error != nil })
    }
}
