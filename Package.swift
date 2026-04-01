// swift-tools-version:5.9

import PackageDescription

let version = "2.1.7"
let checksum = "1303c5ec4ad70c49477d9a31c84b4a19210d66ba5a10bda05d59fbc848c43c6f"

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
