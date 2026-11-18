// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppleDeviceCodegenFixture",
    platforms: [
        .iOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "AppleDeviceCodegenFixture", targets: ["AppleDeviceCodegenFixture"])
    ],
    dependencies: [
        .package(path: "../../../../platform/macos")
    ],
    targets: [
        .target(
            name: "AppleDeviceCodegenFixture",
            dependencies: [
                .product(name: "RivetRuntime", package: "macos"),
                .product(name: "RivetDevice", package: "macos"),
                // The generated RVT1 device surface extends
                // RivetDeviceAppleRVT1Client behind canImport, so the
                // fixture links the transport to compile that surface for
                // iOS and watchOS.
                .product(name: "RivetDeviceAppleTransport", package: "macos")
            ]
        )
    ]
)
