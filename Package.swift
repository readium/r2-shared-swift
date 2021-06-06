// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "R2Shared",
    defaultLocalization: "en",
    platforms: [.iOS(.v10)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "R2Shared",
            targets: ["R2Shared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/marmelroy/Zip.git", from: "2.1.1"),
        .package(url: "https://github.com/cezheng/Fuzi.git", from: "3.1.3"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "R2Shared",
            dependencies: ["Zip", "Fuzi"],
            path: "./r2-shared-swift/",
            exclude: ["Info.plist", "Toolkit/Archive/ZIPFoundation.swift"]
        ),
        .testTarget(
            name: "r2-shared-swiftTests",
            dependencies: ["R2Shared"],
            path: "./r2-shared-swiftTests/",
            exclude: ["Info.plist"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
