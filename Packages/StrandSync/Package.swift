// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StrandSync",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "StrandSync", targets: ["StrandSync"])],
    dependencies: [
        .package(path: "../WhoopProtocol"),
        .package(path: "../WhoopStore"),
    ],
    targets: [
        .target(name: "StrandSync", dependencies: ["WhoopProtocol", "WhoopStore"]),
        .testTarget(name: "StrandSyncTests", dependencies: ["StrandSync"]),
    ]
)
