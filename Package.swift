// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "S02LBKit",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "S02LBKit",
            targets: ["S02LBKit"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "S02LBKit",
            path: "S02LB",
            exclude: ["Resources/Info.plist", "Resources/S02LB.entitlements"]
        ),
        .testTarget(
            name: "S02LBTests",
            dependencies: ["S02LBKit"],
            path: "S02LBTests"
        ),
    ]
)
