// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Luma", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "ImageSearch", targets: ["Luma"]),
    // The engine on its own, for tools such as benchmarks.
    .library(name: "LumaKit", targets: ["LumaKit"]),
  ],
  targets: [
    // UI-free core: the search engine (Core ML, SQLite, Accelerate), preferences, formatting.
    .target(name: "LumaKit"),
    .executableTarget(name: "Luma", dependencies: ["LumaKit"]),
    .testTarget(name: "LumaKitTests", dependencies: ["LumaKit"]),
    // App state against a stand-in engine, plus the real app end to end (opt in with LUMA_E2E=1).
    .testTarget(name: "LumaTests", dependencies: ["Luma", "LumaKit"]),
  ])
