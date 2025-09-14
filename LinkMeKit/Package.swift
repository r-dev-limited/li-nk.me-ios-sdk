// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LinkMeKit",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "LinkMeKit",
            targets: ["LinkMeKit"]
        ),
    ],
    targets: [
        .target(
            name: "LinkMeKit",
            path: "Sources"
        ),
        .testTarget(
            name: "LinkMeKitTests",
            dependencies: ["LinkMeKit"],
            path: "Tests"
        ),
    ]
)

