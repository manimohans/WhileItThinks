// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhileItThinksApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WhileItThinks", targets: ["WhileItThinksApp"])
    ],
    targets: [
        .executableTarget(name: "WhileItThinksApp")
    ]
)
