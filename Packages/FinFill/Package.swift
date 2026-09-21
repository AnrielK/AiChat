// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FinFill",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FinFillCore", targets: ["FinFillCore"]),
        .library(name: "FinFillUI", targets: ["FinFillUI"]),
        .executable(name: "finfill", targets: ["finfill-cli"]),
    ],
    targets: [
        // Pure Foundation: SEC data, iXBRL parser, mapping, validation, Google Sheets, summary.
        // Builds on iOS, macOS and Linux.
        .target(
            name: "FinFillCore",
            resources: [.process("Resources")]
        ),
        // SwiftUI screen for AIChat (Apple platforms only).
        .target(name: "FinFillUI", dependencies: ["FinFillCore"]),
        // Command line tool for testing on a Mac (offline with a local 10-K, or online).
        .executableTarget(name: "finfill-cli", dependencies: ["FinFillCore"]),
        .testTarget(
            name: "FinFillCoreTests",
            dependencies: ["FinFillCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
