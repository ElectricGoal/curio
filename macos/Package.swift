// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Curio", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Curio", targets: ["Curio"]),
    // The engine on its own, for tools such as benchmarks.
    .library(name: "CurioKit", targets: ["CurioKit"]),
  ],
  targets: [
    // UI-free core: the search engine (Core ML, SQLite, Accelerate), preferences, formatting.
    .target(name: "CurioKit"),
    .executableTarget(name: "Curio", dependencies: ["CurioKit"]),
    .testTarget(name: "CurioKitTests", dependencies: ["CurioKit"]),
    // App state against a stand-in engine, plus the real app end to end (opt in with CURIO_E2E=1).
    .testTarget(name: "CurioTests", dependencies: ["Curio", "CurioKit"]),
  ])
