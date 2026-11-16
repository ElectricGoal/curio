import Foundation

/// Where this copy of the app keeps its data: models, caches, timings, settings.
///
/// An **installed** copy (from the disk image) uses the user's Application
/// Support folder. A **checkout** build, made from a source tree, keeps
/// everything inside that tree so development never touches the user's data.
public struct Installation: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case installed, checkout }

  public static let dataFolderName = "Curio"
  /// A file that only exists at the root of this project's source tree.
  static let sourceTreeMarker = "macos/Package.swift"

  public let kind: Kind
  /// Must be writable.
  public let dataRoot: URL

  public init(kind: Kind, dataRoot: URL) {
    self.kind = kind
    self.dataRoot = dataRoot
  }

  public static func checkout(_ root: URL) -> Installation {
    // One spelling, with no trailing slash.
    Installation(kind: .checkout, dataRoot: URL(fileURLWithPath: root.path))
  }

  /// Works out how this copy of the app was built.
  ///
  /// Explicit overrides win (`CURIO_PROJECT_ROOT`, then
  /// `CURIO_DATA_ROOT`); then the source tree the bundle was linked to at
  /// build time; then a source tree found above the bundle (`swift run`);
  /// otherwise this is an installed copy.
  public static func resolve(
    environment: [String: String], linkedProjectRoot: String?, bundle: URL,
    applicationSupport: URL, currentDirectory: URL,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> Installation {
    if let root = environment["CURIO_PROJECT_ROOT"], !root.isEmpty {
      return .checkout(URL(fileURLWithPath: root))
    }
    if let data = environment["CURIO_DATA_ROOT"], !data.isEmpty {
      return Installation(kind: .installed, dataRoot: URL(fileURLWithPath: data))
    }
    if let linkedProjectRoot, !linkedProjectRoot.isEmpty {
      return .checkout(URL(fileURLWithPath: linkedProjectRoot))
    }
    var candidate = bundle
    for _ in 0..<8 {
      if fileExists(candidate.appendingPathComponent(sourceTreeMarker).path) {
        return .checkout(candidate)
      }
      candidate.deleteLastPathComponent()
    }
    return Installation(
      kind: .installed, dataRoot: applicationSupport.appendingPathComponent(dataFolderName))
  }
}
