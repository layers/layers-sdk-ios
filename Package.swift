// swift-tools-version:5.9

import PackageDescription

let version = "1.0.1"
let checksum = "8814656a9f95084873fe10c104dbb912b6d5a2d7815baaedf213a69937a72389"

let package = Package(
    name: "Layers",
    platforms: [
        .iOS(.v14),
        .macOS(.v12),
        .tvOS(.v14),
        .watchOS(.v7),
    ],
    products: [
        .library(
            name: "Layers",
            targets: ["Layers"]
        ),
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "LayersCoreFFI",
            url: "https://github.com/layers/layers-sdk-ios/releases/download/\(version)/LayersCoreFFI.xcframework.zip",
            checksum: checksum
        ),
        .target(
            name: "Layers",
            dependencies: ["LayersCoreFFI"],
            path: "Sources/Layers"
        ),
    ]
)
