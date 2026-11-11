// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Foluna",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Foluna", targets: ["Foluna"]),
        .library(name: "FolunaCore", targets: ["FolunaCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        // Pont C vers libmtp, chargée dynamiquement (dlopen) : aucune dépendance à la compilation.
        .target(name: "CMTPShim"),
        .target(
            name: "FolunaCore",
            dependencies: ["ZIPFoundation", "CMTPShim"]
        ),
        .executableTarget(
            name: "Foluna",
            dependencies: ["FolunaCore"]
        ),
        .testTarget(
            name: "FolunaCoreTests",
            dependencies: ["FolunaCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
