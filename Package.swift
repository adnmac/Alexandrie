// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Alexandrie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Alexandrie", targets: ["Alexandrie"]),
        .library(name: "AlexandrieCore", targets: ["AlexandrieCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        // Pont C vers libmtp, chargée dynamiquement (dlopen) : aucune dépendance à la compilation.
        .target(name: "CMTPShim"),
        .target(
            name: "AlexandrieCore",
            dependencies: ["ZIPFoundation", "CMTPShim"]
        ),
        .executableTarget(
            name: "Alexandrie",
            dependencies: ["AlexandrieCore"]
        ),
        .testTarget(
            name: "AlexandrieCoreTests",
            dependencies: ["AlexandrieCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
