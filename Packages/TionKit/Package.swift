// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TionKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TionKit", targets: ["TionKit"]),
    ],
    targets: [
        .target(name: "TionKit"),
        .testTarget(name: "TionKitTests", dependencies: ["TionKit"]),
    ]
)
