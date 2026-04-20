// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Markzzy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Markzzy", targets: ["Markzzy"]),
    ],
    targets: [
        .executableTarget(
            name: "Markzzy",
            path: "Sources/Markzzy"
        ),
        .testTarget(
            name: "MarkzzyTests",
            dependencies: ["Markzzy"],
            path: "Tests/MarkzzyTests"
        ),
        .testTarget(
            name: "MarkzzyE2ETests",
            dependencies: ["Markzzy"],
            path: "Tests/MarkzzyE2ETests"
        ),
    ]
)
