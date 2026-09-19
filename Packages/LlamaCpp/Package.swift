// swift-tools-version: 5.9
// llama.cpp jako XCFramework.
//
// Když vedle tohoto souboru leží složka llama.xcframework (optimalizovaný build z workflow
// llama-xcframework.yml – build IPA ji stáhne sám), použije se ta. Jinak oficiální
// XCFramework z GitHub Releases. Novější oficiální verze: změň číslo buildu v URL a checksum
// spočítej příkazem
//   swift package compute-checksum llama-bXXXX-xcframework.zip
import Foundation
import PackageDescription

let localFramework = Context.packageDirectory + "/llama.xcframework"
let llamaTarget: Target = FileManager.default.fileExists(atPath: localFramework)
    ? .binaryTarget(name: "llama", path: "llama.xcframework")
    : .binaryTarget(
        name: "llama",
        url: "https://github.com/ggml-org/llama.cpp/releases/download/b10894/llama-b10894-xcframework.zip",
        checksum: "85c1c7aa0f6710a9b241df9629c0b9721e6b7af3a2af48d77119dbdd746989a4"
    )

let package = Package(
    name: "LlamaCpp",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "llama", targets: ["llama"])
    ],
    targets: [llamaTarget]
)
