// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteDesk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RemoteDesk", targets: ["RemoteDesk"])
    ],
    targets: [
        .executableTarget(
            name: "RemoteDesk",
            path: "Sources/RemoteDesk",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "RemoteDeskTests",
            dependencies: ["RemoteDesk"],
            path: "Tests/RemoteDeskTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
