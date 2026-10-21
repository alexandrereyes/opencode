// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenCodeKit",
    platforms: [.iOS("27.0"), .macOS(.v15)],
    products: [.library(name: "OpenCodeKit", targets: ["OpenCodeKit"])],
    targets: [
        .target(name: "OpenCodeKit"),
        .testTarget(name: "OpenCodeKitTests", dependencies: ["OpenCodeKit"], resources: [.process("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
