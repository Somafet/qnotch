// swift-tools-version: 5.9
import PackageDescription

// The Calculator module's engine: a native Swift port of src/QNotch.Calculator.Engine (C#).
// UI-free and dependency-free; the C# engine and tests/fixtures/calculator are its behavioural contract.
let package = Package(
    name: "QNotchCalculator",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CalculatorEngine", targets: ["CalculatorEngine"])],
    targets: [
        .target(name: "CalculatorEngine", resources: [.copy("Resources")]),
        .testTarget(name: "CalculatorEngineTests", dependencies: ["CalculatorEngine"])
    ]
)
