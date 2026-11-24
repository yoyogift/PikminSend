// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PikminSend",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PikminSend", targets: ["PikminSend"])
    ],
    targets: [
        .executableTarget(
            name: "PikminSend",
            path: "Sources/PikminSend"
        )
    ]
)
