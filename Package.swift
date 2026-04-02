// swift-tools-version:5.9

import PackageDescription

let version = "2.1.9"
let checksum = "ea5292212e4fad67afeb359d76b957534d1c4d7106cf1f1b2bfc51c2b5977ddc"

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
