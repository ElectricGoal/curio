import Foundation

/// Finds MLX's compiled Metal shaders (`mlx.metallib`), without which nothing
/// MLX does on the GPU can run.
///
/// Built by `scripts/build-mlx-shaders.sh`; `scripts/build-app.sh` puts a copy
/// inside the app.
public enum MLXShaders {
  public static let fileName = "mlx.metallib"
  public static let environmentKey = "CURIO_MLX_SHADERS"
  static let missingMessage =
    "The app is missing its GPU shaders (mlx.metallib). From a source checkout, run “bash scripts/build-mlx-shaders.sh”."

  /// The first of these that exists: a path given in the environment, the
  /// app's resources, beside the program, a source checkout's build folder.
  public static func locate(
    environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main,
    projectRoot: URL? = nil
  ) -> URL? {
    var candidates: [URL] = []
    if let path = environment[environmentKey], !path.isEmpty {
      candidates.append(URL(fileURLWithPath: path))
    }
    if let resources = bundle.resourceURL {
      candidates.append(resources.appendingPathComponent(fileName))
    }
    if let program = bundle.executableURL {
      candidates.append(program.deletingLastPathComponent().appendingPathComponent(fileName))
    }
    if let projectRoot {
      candidates.append(projectRoot.appendingPathComponent("macos/.build").appendingPathComponent(fileName))
    }
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
  }
}
