// swift-tools-version: 6.2
import PackageDescription

// Atmosplorer — SwiftUI desktop client over the zat AT Protocol explorer
// core. The ZatExplorer wrapper package (../zat-swift) is the only
// dependency; the app never talks to the C ABI directly.
//
// The testable core (AppSession async bridge, AppError mapping) lives in the
// ZatAppCore library so it can be exercised offline with ZatFakeTransport;
// the Atmosplorer executable is the SwiftUI shell on top.
let package = Package(
    name: "Atmosplorer",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "ZatAppCore", targets: ["ZatAppCore"]),
        .executable(name: "Atmosplorer", targets: ["Atmosplorer"]),
    ],
    dependencies: [
        .package(path: "../zat-swift"),
    ],
    targets: [
        // Async session bridge + user-facing error mapping. No SwiftUI here.
        .target(
            name: "ZatAppCore",
            dependencies: [
                .product(name: "ZatExplorer", package: "zat-swift"),
            ],
            path: "Sources/ZatAppCore"
        ),

        // The SwiftUI app.
        .executableTarget(
            name: "Atmosplorer",
            dependencies: [
                "ZatAppCore",
                .product(name: "ZatExplorer", package: "zat-swift"),
            ],
            path: "Sources/Atmosplorer"
        ),

        .testTarget(
            name: "ZatAppCoreTests",
            dependencies: [
                "Atmosplorer",
                "ZatAppCore",
                .product(name: "ZatExplorer", package: "zat-swift"),
            ],
            path: "Tests/ZatAppCoreTests",
            resources: [
                // Live-test fixture data (dual-role repos), kept out of the
                // Swift sources so maintainers can add/retire fixtures by
                // editing JSON only.
                .copy("Fixtures"),
            ]
        ),
    ]
)
