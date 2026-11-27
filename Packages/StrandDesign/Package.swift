// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandDesign",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "StrandDesign", targets: ["StrandDesign"])],
    dependencies: [],
    targets: [
        .target(name: "StrandDesign"),
        .testTarget(name: "StrandDesignTests", dependencies: ["StrandDesign"]),
    ]
)
