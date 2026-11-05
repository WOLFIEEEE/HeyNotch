// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeyNotchMCP",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "heynotch-mcp", targets: ["heynotch-mcp"])],
    targets: [
        .target(name: "HeyNotchMCPCore"),
        .executableTarget(name: "heynotch-mcp", dependencies: ["HeyNotchMCPCore"]),
        .testTarget(name: "HeyNotchMCPCoreTests", dependencies: ["HeyNotchMCPCore"])
    ],
    swiftLanguageModes: [.v5]
)
