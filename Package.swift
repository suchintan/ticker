// swift-tools-version:5.8
// This manifest is for Xcode and CI environments with a full macOS platform SDK.
// CLT-only machines must use Scripts/build-app.sh and Scripts/run-tests.sh.
import PackageDescription

let package = Package(
    name: "Ticker",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TickerCore", targets: ["TickerCore"]),
        .executable(name: "ticker", targets: ["ticker"]),
        .executable(name: "TickerApp", targets: ["TickerApp"]),
    ],
    targets: [
        .target(name: "TickerCore"),
        .executableTarget(name: "ticker", dependencies: ["TickerCore"]),
        .executableTarget(name: "TickerApp", dependencies: ["TickerCore"]),
        // Tests use the dependency-free direct-swiftc runner on every supported machine.
    ]
)
