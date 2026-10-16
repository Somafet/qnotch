// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QNotchMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "QNotch", targets: ["QNotchMacApp"])],
    targets: [
        .target(name: "QNotchMacCore"),
        .target(name: "QNotchMac", dependencies: ["QNotchMacCore"]),
        .executableTarget(name: "QNotchMacApp", dependencies: ["QNotchMac"]),
        .testTarget(name: "QNotchMacTests", dependencies: ["QNotchMacCore", "QNotchMac"])
    ]
)
