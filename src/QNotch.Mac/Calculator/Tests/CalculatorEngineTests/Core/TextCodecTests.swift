import XCTest
@testable import CalculatorEngine

final class TextCodecTests: XCTestCase {
    private func last(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> LineResult {
        let result = try SheetEvaluator.evaluate(source).last!
        XCTAssertNil(result.error, source, file: file, line: line); XCTAssertNotNil(result.value, source, file: file, line: line)
        return result
    }
    private static func isFormat(_ error: Error) -> Bool { (error as? CalcError)?.isFormat == true }
    /// C# compares strings ordinally; Swift's String == would accept canonically equivalent text.
    private static func units(_ text: String) -> [UInt16] { Array(text.utf16) }
    private static func bytes(hex: String) -> [UInt8] {
        let u = Array(hex.utf8); return stride(from: 0, to: u.count, by: 2).map { UInt8(String(decoding: u[$0..<($0 + 2)], as: UTF8.self), radix: 16)! }
    }

    func testIndependentByteCodecAndDigestOracle() throws {
        let cases = try JSONNode.parse(try Fixtures.data("text-codecs-v1.json")).property("cases").arrayItems()
        for row in cases {
            CaseCounter.record(file: #filePath)
            let source = try row.property("source").string()
            do {
                let result = try last(source); let value = try XCTUnwrap(result.value)
                let expected = try row.property("output").string()
                XCTAssertEqual(TextCodecTests.units(expected), TextCodecTests.units(try value.text.value), source)
                XCTAssertEqual(TextCodecTests.units(expected.utf16.contains(0) ? try value.text.expressionText : expected), TextCodecTests.units(try value.copyText), source)
                XCTAssertEqual(TextCodecTests.units(expected), TextCodecTests.units(try last(try value.text.expressionText).value!.text.value), source)
                let evidence = try XCTUnwrap(result.explanation.last { $0.textTransform != nil }?.textTransform, source)
                let bytes = TextCodecTests.bytes(hex: try row.property("inputUtf8").string())
                XCTAssertEqual(bytes.count, evidence.inputUtf8Bytes, source); XCTAssertEqual(expected.utf8.count, evidence.outputUtf8Bytes, source)
                XCTAssertEqual(TextCodecTests.units(try row.property("input").string()), TextCodecTests.units(evidence.input), source)
                XCTAssertEqual(TextCodecTests.units(expected), TextCodecTests.units(evidence.output), source)
                XCTAssertEqual(TextArithmetic.hex(bytes.prefix(32)) + (bytes.count > 32 ? "…" : ""), evidence.inputBytePreview, source)
            } catch { XCTFail("\(source): \(error)") }
        }
    }

    func testPublishedCommandsAndLiteralPreservation() throws {
        try theory([("base64 \"hello\"", "aGVsbG8="), ("base64 hello", "aGVsbG8="), ("decode base64 aGVsbG8=", "hello"), ("urlencode \"a b&c\"", "a%20b%26c"),
                    ("md5 abc", "900150983cd24fb0d6963f7d28e17f72"), ("sha256 \"abc\"", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
                    ("sha1 abc", "a9993e364706816aba3e25717850c26c9cd0d89d"), ("decode base64 YT1iI2MgLy9k", "a=b#c //d"),
                    ("urlencode https://example.test/a//b?x=1&y=two words#part", "https%3A%2F%2Fexample.test%2Fa%2F%2Fb%3Fx%3D1%26y%3Dtwo%20words%23part"),
                    ("urldecode a+b%20c%2fd%23x", "a+b c/d#x"), ("x=base64 hello\ndecodeBase64(x)", "hello"), ("base64 \"hello\" #demo // note", "aGVsbG8="),
                    ("x=text(\"a=b #t //comment\")\nx", "a=b #t //comment"),
                    ("text(\"+\")", "+"), ("text(\"-\")", "-"), ("text(\"in\")", "in"),
                    ("text(\"until\")", "until"), ("text(\"is\")", "is"), ("text(\"at\")", "at"),
                    ("text(\"\\uD83D\\uDE00\")", "😀"), ("text(\"\\u0000\")", "\0"),
                    ("text(\"  space  \\n\")", "  space  \n")]) { source, expected in
            XCTAssertEqual(TextCodecTests.units(expected), TextCodecTests.units(try last(source).value!.text.value), source)
        }
    }

    func testQuotedCommentsAndOrdinaryNamesRemainCompatible() throws {
        try theory([("\"label #tag // =\" 2+2", "4"), ("2 \"unrecognized \\q escape remains a comment\" +2", "4"), ("sqrt(\"note\" 4)", "2"),
                    ("base64=7\nbase64+1", "8"), ("x=2\n\"md5 abc\" x+2", "4")]) { source, expected in
            XCTAssertEqual(expected, try last(source).display, source)
        }
    }

    func testMalformedBytesTypesAndLiteralsAreErrors() throws {
        try theory(["decode base64 Zg", "decode base64 Zh==", "decode base64 Zg===",
                    "decodeBase64(\"Z g==\")", "decodeBase64(\"_w==\")", "decodeBase64(\"/w==\")",
                    "urldecode %", "urldecode %1", "urldecode %GG", "urldecode %FF", "urldecode %C0%AF",
                    "text(\"\\uD800\")", "text(\"\\uDC00\")", "text(\"\\uD800x\")", "text(\"\\q\")",
                    "text(\"unterminated)", "text()", "base64(1)", "sha256(1 USD)", "md5(\"a\",\"b\")",
                    "text(\"2\")+1", "text(\"2\")&1", "base64(missing)"]) { source in
            XCTAssertNotNil(try SheetEvaluator.evaluate(source).last!.error, source)
        }
    }

    func testDataCaseSurvivesDefinitionIdentityReceiptsAndCaching() throws {
        let first = try FunctionUpdate.prepare("digest()=md5(\"a\")", .empty, [])
        let changed = try FunctionUpdate.prepare("digest()=md5(\"A\")", first.library, first.receipts)
        XCTAssertNotEqual(first.library.fingerprint, changed.library.fingerprint); XCTAssertTrue(changed.hasChanges)
        let session = SheetEvaluationSession()
        XCTAssertEqual("0cc175b9c0f1b6a831c399e269772661", try session.evaluateWithFunctions("digest()", first.library, []).results[0].display)
        XCTAssertEqual("7fc56270e7a70fa81a5935b72eacbe29", try session.evaluateWithFunctions("digest()", changed.library, []).results[0].display)
        let library = try FunctionLibrary([FunctionDefinition(name: "enc", parameters: ["x"], body: "base64(x)"), FunctionDefinition(name: "natural", parameters: [], body: "base64 hello")])
        let results = try SheetEvaluationSession().evaluateWithFunctions("enc(text(\"hello\"))\nnatural()", library, []).results
        for result in results { XCTAssertEqual("aGVsbG8=", result.display) }
    }

    func testInvalidLiteralDefinitionsBlockEarlierSavedFunctions() throws {
        try theory(["digest()=base64 \"\\uD800\"\ndigest()", "digest()=sha256(\"\\uD800\")\ndigest()"]) { source in
            let library = try FunctionLibrary([FunctionDefinition(name: "digest", parameters: [], body: "md5(\"a\")")])
            let results = try SheetEvaluationSession().evaluateWithFunctions(source, library, []).results
            XCTAssertNotNil(results[0].error, source); XCTAssertNotNil(results[1].error, source); XCTAssertNil(results[1].value, source)
        }
    }

    func testCanonicalEscapesHaveTheSameIdentityWithoutNormalizingUnicode() throws {
        let a = try FunctionLibrary([FunctionDefinition(name: "v", parameters: [], body: "text(\"a\")")])
        let escaped = try FunctionLibrary([FunctionDefinition(name: "v", parameters: [], body: "text(\"\\u0061\")")])
        XCTAssertEqual(a.fingerprint, escaped.fingerprint)
        let composed = try last("sha256(\"é\")").value!.text.value; let decomposed = try last("sha256(\"e\\u0301\")").value!.text.value
        XCTAssertNotEqual(TextCodecTests.units(composed), TextCodecTests.units(decomposed))
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "bad", parameters: [], body: "md5()")])) { XCTAssertTrue(TextCodecTests.isFormat($0)) }
    }

    func testFullCopiesAndEscapedPreviewsRemainDistinctAndBounded() throws {
        let payload = String(repeating: "😀", count: 16384)
        let expression = "text(" + NetJSONText.quote(payload) + ")"
        let value = try XCTUnwrap(try last(expression).value)
        XCTAssertEqual(TextCodecTests.units(payload), TextCodecTests.units(try value.copyText)); XCTAssertTrue(try value.display.netLength <= 128); XCTAssertTrue(try value.display.contains("…"))
        XCTAssertEqual(TextCodecTests.units(payload), TextCodecTests.units(try last(try value.text.expressionText).value!.text.value))
        XCTAssertEqual("\\n\\u0000", try last("text(\"\\n\\u0000\")").display)
        XCTAssertNotNil(try SheetEvaluator.evaluate("urlencode(" + NetJSONText.quote(payload) + ")")[0].error)
        XCTAssertNotNil(try SheetEvaluator.evaluate("base64(" + NetJSONText.quote(payload) + ")")[0].error)
        XCTAssertThrowsError(try TextValue(String(repeating: "x", count: 32769))) { XCTAssertTrue(($0 as? CalcError)?.isArithmetic == true) }
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate(expression, cancellation)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
}
