// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Splitroute",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Splitroute", targets: ["Splitroute"]),
        .executable(name: "splitroute-helper", targets: ["splitroute-helper"]),
    ],
    targets: [
        .target(
            name: "SplitrouteCore",
            linkerSettings: [.linkedFramework("SystemConfiguration")]
        ),
        .executableTarget(
            name: "splitroute-helper",
            dependencies: ["SplitrouteCore"]
        ),
        .executableTarget(
            name: "Splitroute",
            dependencies: ["SplitrouteCore"],
            path: "Sources/SplitrouteApp"
        ),
        .testTarget(
            name: "SplitrouteCoreTests",
            dependencies: ["SplitrouteCore"]
        ),
    ]
)
