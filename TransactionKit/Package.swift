// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TransactionKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "TransactionKit", targets: ["TransactionKit"]),
        .library(name: "Networking", targets: ["Networking"])
    ],
    targets: [
        .target(name: "TransactionKit"),
        .target(
            name: "Networking",
            dependencies: ["TransactionKit"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "TransactionKitTests",
            dependencies: ["TransactionKit"],
            resources: [.copy("TestResources")]
        ),
        .testTarget(
            name: "NetworkingTests",
            dependencies: ["Networking", "TransactionKit"],
            resources: [.copy("TestResources")]
        )
    ]
)
