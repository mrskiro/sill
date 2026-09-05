// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SillCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "SillCore", targets: ["SillCore"]),
        // macOS-only helpers and third-party dependencies for the Mac app (kept here so
        // Package.resolved pins them and Dependabot sees them).
        .library(name: "SillMac", targets: ["SillMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.20.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "3.0.1"),
    ],
    targets: [
        .target(
            name: "SillCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .target(
            name: "SillMac",
            dependencies: [
                "SillCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .testTarget(
            name: "SillCoreTests",
            dependencies: ["SillCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
