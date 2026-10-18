// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BiliKitCore",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "BiliModels", targets: ["BiliModels"]),
        .library(name: "BiliApplication", targets: ["BiliApplication"]),
        .library(name: "BiliNetworking", targets: ["BiliNetworking"]),
        .library(name: "BiliAuth", targets: ["BiliAuth"]),
        .library(name: "BiliAPI", targets: ["BiliAPI"]),
        .library(name: "BiliPlayback", targets: ["BiliPlayback"]),
        .library(name: "BiliDanmaku", targets: ["BiliDanmaku"]),
        .library(name: "BiliBrowseFeature", targets: ["BiliBrowseFeature"]),
        .library(name: "BiliAuthFeature", targets: ["BiliAuthFeature"]),
        .library(name: "BiliLibraryFeature", targets: ["BiliLibraryFeature"]),
        .library(name: "BiliVideoDetailFeature", targets: ["BiliVideoDetailFeature"]),
        .library(name: "BiliVideoCollectionUI", targets: ["BiliVideoCollectionUI"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            exact: "1.38.1"
        )
    ],
    targets: [
        .target(name: "BiliModels"),
        .target(
            name: "BiliApplication",
            dependencies: ["BiliModels"]
        ),
        .target(name: "BiliNetworking"),
        .target(
            name: "BiliAuth",
            dependencies: ["BiliApplication", "BiliModels", "BiliNetworking"]
        ),
        .target(
            name: "BiliAPI",
            dependencies: [
                "BiliApplication",
                "BiliModels",
                "BiliNetworking",
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            exclude: ["Remote/Protobuf/danmaku.proto"]
        ),
        .target(
            name: "BiliPlayback",
            dependencies: ["BiliApplication", "BiliModels", "BiliNetworking"]
        ),
        .target(
            name: "BiliDanmaku",
            dependencies: ["BiliApplication", "BiliModels"]
        ),
        .target(
            name: "BiliBrowseFeature",
            dependencies: ["BiliApplication", "BiliModels", "BiliUI", "BiliVideoCollectionUI"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "BiliAuthFeature",
            dependencies: ["BiliApplication", "BiliModels"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "BiliLibraryFeature",
            dependencies: ["BiliApplication", "BiliModels", "BiliUI", "BiliVideoCollectionUI"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "BiliVideoDetailFeature",
            dependencies: ["BiliApplication", "BiliModels", "BiliUI", "BiliVideoCollectionUI"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "BiliUI",
            dependencies: ["BiliApplication"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "BiliVideoCollectionUI",
            dependencies: ["BiliUI"]
        ),
        .testTarget(
            name: "BiliModelsTests",
            dependencies: ["BiliModels"]
        ),
        .testTarget(
            name: "BiliApplicationTests",
            dependencies: ["BiliApplication", "BiliModels"]
        ),
        .testTarget(
            name: "BiliNetworkingTests",
            dependencies: ["BiliNetworking"]
        ),
        .testTarget(
            name: "BiliAuthTests",
            dependencies: ["BiliAuth", "BiliModels", "BiliNetworking"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "BiliAPITests",
            dependencies: [
                "BiliAPI", "BiliApplication", "BiliModels", "BiliNetworking"
            ],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "BiliPlaybackTests",
            dependencies: [
                "BiliApplication",
                "BiliModels",
                "BiliNetworking",
                "BiliPlayback"
            ],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "BiliDanmakuTests",
            dependencies: [
                "BiliApplication",
                "BiliDanmaku",
                "BiliModels"
            ]
        ),
        .testTarget(
            name: "BiliBrowseFeatureTests",
            dependencies: [
                "BiliApplication",
                "BiliBrowseFeature",
                "BiliModels",
                "BiliUI",
                "BiliVideoCollectionUI"
            ]
        ),
        .testTarget(
            name: "BiliAuthFeatureTests",
            dependencies: ["BiliApplication", "BiliAuthFeature"]
        ),
        .testTarget(
            name: "BiliLibraryFeatureTests",
            dependencies: ["BiliApplication", "BiliLibraryFeature", "BiliModels"]
        ),
        .testTarget(
            name: "BiliVideoDetailFeatureTests",
            dependencies: [
                "BiliApplication",
                "BiliModels",
                "BiliUI",
                "BiliVideoCollectionUI",
                "BiliVideoDetailFeature"
            ]
        ),
        .testTarget(
            name: "BiliUITests",
            dependencies: ["BiliApplication", "BiliUI"]
        ),
        .testTarget(
            name: "BiliVideoCollectionUITests",
            dependencies: ["BiliUI", "BiliVideoCollectionUI"]
        )
    ]
)

// 只维护发布工具链一个版本：本包所有 target 的编译警告都视为错误。
// 并发与 import 可见性的 upcoming feature 与 App target 保持同一组（见 ARCHITECTURE「平台与命名」）。
let sharedSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility")
]

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + sharedSwiftSettings
}
