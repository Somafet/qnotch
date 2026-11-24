import XCTest
@testable import CalculatorEngine

/// The bundled catalogs are copies of the C# engine's embedded resources; they must not drift.
final class ResourceTests: XCTestCase {
    func testCatalogsMatchTheWindowsEngine() throws {
        let engine = Fixtures.repositoryRoot.appendingPathComponent("src/QNotch.Calculator.Engine")
        for name in ["AtomicWeights.json", "Currencies.json", "Ingredients.json", "LanguageKeywords.json", "ResistorColors.json", "TimeZones.json", "Units.json"] {
            let original = try Data(contentsOf: engine.appendingPathComponent(name))
            XCTAssertEqual(CalculatorEngine.resource(name), original, name)
        }
    }
    /// Tzdb.txt is generated from NodaTime by Tools/TzdbExport (it has no C# file to compare with): it must carry the
    /// manifest's pinned version and hold rules for every manifest id.
    func testEmbeddedZoneRulesCoverTheManifest() throws {
        let provider = Tzdb.provider as! TzdbProvider
        XCTAssertEqual(provider.versionId, ZoneCatalog.manifestVersion)
        let manifest = try JSONNode.parse(CalculatorEngine.resource("TimeZones.json"))
        XCTAssertEqual(try manifest.property("package").string(), "NodaTime 3.3.7")
        for id in ZoneCatalog.ids.sorted() { XCTAssertEqual(provider.zone(id)?.id, id, id) }
        XCTAssertEqual(provider.ids, provider.ids.sorted { String.ordinalCompare($0, $1) < 0 })
    }
}
