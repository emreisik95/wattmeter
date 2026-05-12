// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Wattmeter",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            path: "vendor/Sparkle.xcframework"
        ),
        .executableTarget(
            name: "Wattmeter",
            dependencies: ["Sparkle"],
            path: "Sources/Wattmeter",
            resources: [
                .copy("Resources/pricing.json")
            ],
            swiftSettings: [
                .unsafeFlags(["-Osize", "-wmo"], .when(configuration: .release))
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip",
                              "-Xlinker", "-dead_strip_dylibs",
                              "-Xlinker", "-rpath",
                              "-Xlinker", "@executable_path/../Frameworks"],
                             .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "WattmeterTests",
            dependencies: ["Wattmeter"],
            path: "Tests/WattmeterTests"
        )
    ]
)
