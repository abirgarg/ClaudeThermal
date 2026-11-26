// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeThermal",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeThermal",
            path: "Sources/ClaudeThermal",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        )
    ]
)
