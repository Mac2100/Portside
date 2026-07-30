// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Portside",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Terminal emulator for the in-app container console.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // YAML parsing for docker-compose import.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6")
    ],
    targets: [
        .executableTarget(
            name: "Portside",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/Portside"
        )
    ]
)
