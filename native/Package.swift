// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenTalonNative",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "CompanionCore"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "OpenTalon",
            dependencies: ["CompanionCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
