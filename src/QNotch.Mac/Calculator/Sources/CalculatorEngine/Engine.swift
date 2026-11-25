import Foundation

/// The Calculator engine: a native port of the C# engine in src/QNotch.Calculator.Engine.
enum CalculatorEngine {
    private static let bundleName = "QNotchCalculator_CalculatorEngine.bundle"
    /// The engine's resource bundle: inside the app's Contents/Resources (where build.sh puts it), else SwiftPM's
    /// own location (tests, `swift run`). `Bundle.module` alone would look beside the .app, not inside it.
    private static let bundle: Bundle = {
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let found = Bundle(url: base.appendingPathComponent(bundleName)) { return found }
        }
        return Bundle.module
    }()
    /// The bundled data catalogs (units, currencies, time zones, …), copied byte for byte from the C# engine.
    static func resource(_ name: String) -> Data {
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Resources"),
              let data = try? Data(contentsOf: url) else { fatalError("Missing calculator resource " + name) }
        return data
    }
}
