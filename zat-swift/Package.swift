// swift-tools-version: 6.2
import PackageDescription

// Swift wrapper over the zat AT Protocol explorer core (Zig, C ABI).
//
// The prebuilt static library in Vendor/ is produced by Scripts/sync-zat.sh,
// which runs `zig build` in ../DEVKITS/zat-main and copies the artifacts in.
let package = Package(
    name: "zat-swift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "ZatExplorer", targets: ["Zat"])
    ],
    targets: [
        // Prebuilt zat core static library (arm64-apple-macos), packaged as
        // an xcframework by Scripts/sync-zat.sh. Refresh after changing the
        // Zig side.
        .binaryTarget(name: "ZatC", path: "Vendor/ZatC.xcframework"),

        // C interop: module map over zat.h (ownership contract lives there).
        .target(
            name: "Czat",
            dependencies: ["ZatC"],
            path: "Sources/Czat"
        ),

        // The typed, Swift-idiomatic wrapper.
        .target(
            name: "Zat",
            dependencies: ["Czat"],
            path: "Sources/Zat"
        ),

        .testTarget(
            name: "ZatTests",
            dependencies: ["Zat", "Czat"],
            path: "Tests/ZatTests"
        ),
    ]
)
