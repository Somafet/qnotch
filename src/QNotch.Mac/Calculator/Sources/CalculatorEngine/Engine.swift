import Foundation

/// The Calculator engine: a native port of the C# engine in src/QNotch.Calculator.Engine.
public enum CalculatorEngine {
    /// The bundled data catalogs (units, currencies, time zones, …), copied byte for byte from the C# engine.
    static func resource(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"),
              let data = try? Data(contentsOf: url) else { fatalError("Missing calculator resource " + name) }
        return data
    }
}
