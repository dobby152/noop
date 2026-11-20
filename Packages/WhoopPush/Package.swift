// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhoopPush",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "WhoopPush", targets: ["WhoopPush"])],
    targets: [
        .target(name: "WhoopPush"),
        .testTarget(name: "WhoopPushTests", dependencies: ["WhoopPush"]),
    ]
)
