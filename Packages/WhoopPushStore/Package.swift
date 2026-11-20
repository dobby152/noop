// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhoopPushStore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "WhoopPushStore", targets: ["WhoopPushStore"])],
    dependencies: [
        .package(path: "../WhoopStore"),
        .package(path: "../WhoopPush"),
        // Stejná přesná verze jako ostatní Packages/*/Package.swift a project.yml.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
    ],
    targets: [
        .target(
            name: "WhoopPushStore",
            dependencies: ["WhoopStore", "WhoopPush", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "WhoopPushStoreTests",
            dependencies: ["WhoopPushStore", "WhoopStore", "WhoopPush", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
