// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XPd",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "XPd", targets: ["XPd"])
    ],
    targets: [
        .executableTarget(
            name: "XPd",
            path: "Sources/XPd"
        ),
        .testTarget(
            name: "XPdTests",
            dependencies: ["XPd"]
        )
    ]
)
