// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SillCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "SillCore", targets: ["SillCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.20.0"),
    ],
    targets: [
        .target(
            name: "SillCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .testTarget(
            name: "SillCoreTests",
            dependencies: ["SillCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
