// swift-tools-version:5.9
import PackageDescription

// Reverse-engineering diagnostic for a WHOOP 5.0 strap. Kept out of the app target on purpose:
// it is a research tool, never shipped, and it can only send the read-only allowlist in main.swift.
let package = Package(
    name: "ble_probe",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/WhoopProtocol"),
    ],
    targets: [
        .executableTarget(name: "ble_probe", dependencies: [
            .product(name: "WhoopProtocol", package: "WhoopProtocol"),
        ]),
    ]
)
