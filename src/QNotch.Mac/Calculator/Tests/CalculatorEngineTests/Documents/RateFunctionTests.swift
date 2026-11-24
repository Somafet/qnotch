import XCTest
@testable import CalculatorEngine

final class RateFunctionTests: XCTestCase {
    private var directory = TestFiles.temporary("Calc-rate-tests")
    override func tearDown() { TestFiles.delete(directory) }

    func testRateCatalogSurvivesRestartAndNeverDowngrades() throws {
        let id: UUID
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            id = try store.load().workspace.activeSheetId; let doc = try store.open(id).document
            let source = "savedTransfer(x)=x at 100 Mbps\nsavedCost(x)=x tokens at $3/M\nsavedUp(x)=x uptime for 30 days"
            try store.saveWithFunctions(doc.with { $0.source = source }, try FunctionUpdate.prepare(source, try store.loadFunctions(), []))
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load(); let functions = try reopened.loadFunctions()
        XCTAssertEqual(3, functions.minimumCatalogVersion)
        let results = try SheetEvaluationSession().evaluateWithFunctions("savedTransfer(5 GB)\nsavedCost(1200000)\nsavedUp(99.9%)", functions, []).results
        for r in results { XCTAssertNil(r.error) }
        XCTAssertEqual(["6 min 40 s", "3.6 USD", "43 min 12 s"], results.map(\.display))
        let doc2 = try reopened.open(id).document; let forget = "forget savedTransfer\nforget savedCost\nforget savedUp"
        try reopened.saveWithFunctions(doc2.with { $0.source = forget }, try FunctionUpdate.prepare(forget, functions, try reopened.loadFunctionReceipts(id)))
        XCTAssertEqual(3, try JSONNode.parse(Data(try TestFiles.readBytes(TestFiles.path(directory, "functions.json")))).property("Version").int())
    }
    func testEarlierDevelopmentCatalogMigratesAtomically() throws {
        let base = directory
        try theory([1, 2]) { version in
            directory = TestFiles.path(base, "v\(version)")
            let store = try WorkspaceStore(directory); defer { store.dispose() }; _ = try store.load(); let path = TestFiles.path(directory, "functions.json")
            let original = FunctionCatalog(version, [FunctionDefinition(name: "wire", parameters: [], body: "1 Mbps")]).json; try TestFiles.writeText(path, original)
            XCTAssertEqual(3, try store.loadFunctions().minimumCatalogVersion); XCTAssertEqual(original, try TestFiles.readText(path + ".bak"))
            XCTAssertEqual(3, try JSONNode.parse(Data(try TestFiles.readBytes(path))).property("Version").int())
        }
        directory = base
    }
}
