// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QNotchMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "QNotch", targets: ["QNotchMacApp"])],
    dependencies: [
        // Updates. Pinned exactly; the binary target is checksummed by Sparkle's manifest.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "QNotchMacCore"),
        .target(name: "QNotchTerminalPTY"),
        .target(name: "QNotchMac", dependencies: ["QNotchMacCore", "QNotchTerminalPTY", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "QNotchMacApp", dependencies: ["QNotchMac"],
                          // Sparkle.framework is copied into Contents/Frameworks by build.sh.
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "QNotchMacTests", dependencies: ["QNotchMacCore", "QNotchMac"])
    ]
)
