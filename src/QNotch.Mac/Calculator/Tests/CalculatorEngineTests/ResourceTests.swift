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
}
