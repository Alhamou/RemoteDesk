// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteDesk",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "RemoteDesk",
            path: "Sources/RemoteDesk",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
