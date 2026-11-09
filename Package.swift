// swift-tools-version: 6.0
import PackageDescription

// The benchmark harness for FluidStreamKit, kept in its own package so the library stays
// zero-dependency. Comparisons against other streaming-Markdown libraries add their
// dependencies here, never to FluidStreamKit.
let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "FluidStreamBench",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),        // host-side `swift test`
    ],
    products: [
        .library(name: "FluidStreamBenchmarkKit", targets: ["FluidStreamBenchmarkKit"]),
    ],
    dependencies: [
        // A sibling checkout for now. Switch to the library's git URL once it's published.
        .package(path: "../FluidStreamKit"),
    ],
    targets: [
        .target(
            name: "FluidStreamBenchmarkKit",
            dependencies: [
                .product(name: "FluidStreamCore", package: "FluidStreamKit"),
                .product(name: "FluidStreamUI", package: "FluidStreamKit"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "FluidStreamBenchmarkKitTests",
            dependencies: [
                "FluidStreamBenchmarkKit",
                .product(name: "FluidStreamCore", package: "FluidStreamKit"),
                .product(name: "FluidStreamUI", package: "FluidStreamKit"),
            ],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
