// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Barracks",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BarracksCore", targets: ["BarracksCore"]),
        .executable(name: "BarracksApp", targets: ["BarracksApp"]),
        .executable(name: "barracks", targets: ["BarracksCLI"]),
        .executable(name: "barracks-launcher", targets: ["BarracksLauncher"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
    ],
    targets: [
        .target(
            name: "BarracksCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "BarracksApp",
            dependencies: ["BarracksCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "BarracksCLI", dependencies: ["BarracksCore"]),
        .executableTarget(name: "BarracksLauncher"),
        .testTarget(name: "BarracksCoreTests", dependencies: ["BarracksCore"]),
    ]
)
