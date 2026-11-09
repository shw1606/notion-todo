// swift-tools-version: 6.2
import PackageDescription

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
        .target(name: "NotionKit"),
        .target(name: "TodoCore", dependencies: ["NotionKit"]),
        .target(name: "DesignSystem", dependencies: ["TodoCore"], resources: [.process("Resources")]),
        .testTarget(name: "NotionKitTests", dependencies: ["NotionKit"]),
        .testTarget(name: "TodoCoreTests", dependencies: ["TodoCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
