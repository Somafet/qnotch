import XCTest
@testable import CalculatorEngine

final class EquationFunctionTests: XCTestCase {
    private let directory = TestFiles.temporary("Calc-equation-tests")
    override func tearDown() { TestFiles.delete(directory) }

    func testFormulaCatalogUsesSchemaFourSurvivesRestartAndNeverDowngrades() throws {
        let id: UUID
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            id = try store.load().workspace.activeSheetId; let doc = try store.open(id).document
            let source = "savedArea(b)=integral(x^2,0,b)\nsavedRoots(c)=solve x^2 = c\nsavedSlope(p)=derivative(sin(x),p)"
            try store.saveWithFunctions(doc.with { $0.source = source }, try FunctionUpdate.prepare(source, try store.loadFunctions(), []))
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load(); let functions = try reopened.loadFunctions()
        XCTAssertEqual(FunctionLibrary.formulaCatalogVersion, functions.minimumCatalogVersion)
        let results = try SheetEvaluationSession().evaluateWithFunctions("savedArea(3)\nsavedRoots(4)\nsavedSlope(0)", functions, []).results
        for r in results { XCTAssertNil(r.error) }
        XCTAssertEqual(["9", "x = -2 or x = 2", "≈ 1"], results.map(\.display))
        let doc2 = try reopened.open(id).document; let forget = "forget savedArea\nforget savedRoots\nforget savedSlope"
        try reopened.saveWithFunctions(doc2.with { $0.source = forget }, try FunctionUpdate.prepare(forget, functions, try reopened.loadFunctionReceipts(id)))
        XCTAssertEqual(FunctionLibrary.formulaCatalogVersion, try JSONNode.parse(Data(try TestFiles.readBytes(TestFiles.path(directory, "functions.json")))).property("Version").int())
    }
    func testEarlierCatalogMigratesAndLaterCatalogIsRefusedUntouched() throws {
        let path = TestFiles.path(directory, "functions.json")
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            _ = try store.load(); let original = FunctionCatalog(3, [FunctionDefinition(name: "saved", parameters: ["b"], body: "integral(x,0,b)")]).json; try TestFiles.writeText(path, original)
            XCTAssertEqual(FunctionLibrary.formulaCatalogVersion, try store.loadFunctions().minimumCatalogVersion); XCTAssertEqual(original, try TestFiles.readText(path + ".bak"))
            XCTAssertEqual(FunctionLibrary.formulaCatalogVersion, try JSONNode.parse(Data(try TestFiles.readBytes(path))).property("Version").int())
        }
        let future = "{\"Version\":\(FunctionLibrary.latestCatalogVersion + 1),\"Definitions\":[]}"; try TestFiles.writeText(path, future)
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load()
        assertThrows(.unsupportedVersion, try reopened.loadFunctions()); XCTAssertEqual(future, try TestFiles.readText(path))
    }
}
