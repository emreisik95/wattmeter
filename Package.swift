// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Wattmeter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Wattmeter",
            path: "Sources/Wattmeter",
            swiftSettings: [
                .unsafeFlags(["-Osize", "-wmo"], .when(configuration: .release))
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip",
                              "-Xlinker", "-dead_strip_dylibs"],
                             .when(configuration: .release))
            ]
        )
    ]
)
