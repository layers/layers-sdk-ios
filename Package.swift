// swift-tools-version:5.9

import PackageDescription

let version = "3.2.4"
let checksum = "df0ac1f9b63bcb16e850c7c0e33c711e612c27cb5cc4603fbd7db3390592c980"

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
