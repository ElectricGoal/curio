// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Curio", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Curio", targets: ["Curio"]),
    // The engine on its own, for tools such as benchmarks.
    .library(name: "CurioKit", targets: ["CurioKit"]),
  ],
  dependencies: [
    // Runs the decision model on the GPU. Its Metal shaders are compiled by scripts/build-mlx-shaders.sh.
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0")
  ],
  targets: [
    // UI-free core: the search engine (Core ML and MLX, SQLite, Accelerate), preferences, formatting.
    .target(name: "CurioKit", dependencies: [.product(name: "MLX", package: "mlx-swift")]),
    .executableTarget(name: "Curio", dependencies: ["CurioKit"]),
    .testTarget(name: "CurioKitTests", dependencies: ["CurioKit"]),
    // App state against a stand-in engine, plus the real app end to end (opt in with CURIO_E2E=1).
    .testTarget(name: "CurioTests", dependencies: ["Curio", "CurioKit"]),
  ])
