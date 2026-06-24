// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionMaster",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SessionCore", targets: ["SessionCore"]),
        .executable(name: "recall-probe", targets: ["recall-probe"]),
        .executable(name: "SessionMaster", targets: ["SessionMaster"]),
    ],
    targets: [
        .target(name: "SessionCore"),
        .executableTarget(name: "recall-probe", dependencies: ["SessionCore"]),
        .executableTarget(name: "SessionMaster", dependencies: ["SessionCore"]),
    ]
)
