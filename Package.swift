// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EventKitHttpMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EventKitMCP", targets: ["EventKitMCP"]),
    ],
    targets: [
        // EventKit access, calendar sync, MCP protocol and the loopback HTTP server.
        .target(name: "EventKitMCPCore"),
        // Menu bar app (AppKit + SwiftUI) that hosts the server.
        .executableTarget(name: "EventKitMCP", dependencies: ["EventKitMCPCore"]),
        .testTarget(name: "EventKitMCPCoreTests", dependencies: ["EventKitMCPCore"]),
    ],
    swiftLanguageModes: [.v5]
)
