// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "anthopric-proxy",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.20.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.31.0"),
        .package(url: "https://github.com/sebsto/soto-core.git", branch: "sebsto/sso_credential_provider"), //from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "SotoCore", package: "soto-core"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Configuration", package: "swift-configuration"),
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
