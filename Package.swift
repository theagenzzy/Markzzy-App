// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Markzzy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Markzzy", targets: ["Markzzy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Markzzy",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
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
