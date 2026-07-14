// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SqueakyClean",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SqueakyCleanCore",
            targets: ["SqueakyCleanCore"]
        ),
        .executable(
            name: "SqueakyClean",
            targets: ["SqueakyCleanApp"]
        )
    ],
    targets: [
        .target(
            name: "SqueakyCleanCore"
        ),
        .executableTarget(
            name: "SqueakyCleanApp",
            dependencies: ["SqueakyCleanCore"]
        ),
        .testTarget(
            name: "SqueakyCleanCoreTests",
            dependencies: ["SqueakyCleanCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
