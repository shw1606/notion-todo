// swift-tools-version: 6.2
import PackageDescription

// 화면 몇 개짜리 앱이라 속도보다 크기를 고른다 (앱 타깃의 Release 설정과 같다. DECISIONS 2026-11-11).
let sizeFirst: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

let package = Package(
    name: "NotionTodoKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NotionKit", targets: ["NotionKit"]),
        .library(name: "TodoCore", targets: ["TodoCore"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    targets: [
        .target(name: "NotionKit", swiftSettings: sizeFirst),
        .target(name: "TodoCore", dependencies: ["NotionKit"], swiftSettings: sizeFirst),
        .target(
            name: "DesignSystem", dependencies: ["TodoCore"], resources: [.process("Resources")], swiftSettings: sizeFirst),
        .testTarget(name: "NotionKitTests", dependencies: ["NotionKit"]),
        .testTarget(name: "TodoCoreTests", dependencies: ["TodoCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
    ],
    swiftLanguageModes: [.v6]
)
