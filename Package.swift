// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetWatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NetWatch", targets: ["NetWatch"])
    ],
    targets: [
        .executableTarget(
            name: "NetWatch",
            path: "Sources/NetWatch",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
