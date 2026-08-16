// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FulcrumKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FulcrumKit", targets: ["FulcrumKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")
    ],
    targets: [
        .target(
            name: "FulcrumKit",
            dependencies: ["Yams"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FulcrumKitTests",
            dependencies: ["FulcrumKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
