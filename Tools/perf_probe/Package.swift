// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "perf_probe",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandAnalytics"),
        .package(path: "../../Packages/WhoopStore"),
        .package(path: "../../Packages/WhoopProtocol"),
    ],
    targets: [
        .executableTarget(name: "perf_probe", dependencies: [
            .product(name: "StrandAnalytics", package: "StrandAnalytics"),
            .product(name: "WhoopStore", package: "WhoopStore"),
            .product(name: "WhoopProtocol", package: "WhoopProtocol"),
        ]),
    ]
)
