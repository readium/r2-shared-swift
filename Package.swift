// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "r2-shared-swift",
    platforms: [.iOS(.v10)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "r2-shared-swift",
            targets: ["r2-shared-swift"]),
    ],
    dependencies: [
        .package(url: "https://github.com/marmelroy/Zip.git", .exact("2.1.1")),
        .package(url: "https://github.com/cezheng/Fuzi.git", .exact("3.1.3")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "r2-shared-swift",
            dependencies: ["Zip", "Fuzi"]),
        .testTarget(
            name: "r2-shared-swiftTests",
            dependencies: ["r2-shared-swift"]),
    ]
)
