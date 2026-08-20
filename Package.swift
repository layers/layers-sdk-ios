// swift-tools-version:5.9

import PackageDescription

let version = "3.2.12"
let checksum = "08d3700ba31d74c95336c7d4cfd4d515de78e742c2926a241f73e210fe9e1687"

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
        .library(
            name: "LayersTesting",
            targets: ["LayersTesting"]
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
            path: "Sources/Layers",
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ]
        ),
        .target(
            name: "LayersTesting",
            dependencies: ["Layers"],
            path: "Sources/LayersTesting"
        ),
    ]
)
