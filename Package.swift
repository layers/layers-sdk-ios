// swift-tools-version:5.9

import PackageDescription

let version = "2.1.1"
let checksum = "25992987ee3b6f57af6ffbc63c85f687cf7121d0a38424b23d10e1c296aae0a5"

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
