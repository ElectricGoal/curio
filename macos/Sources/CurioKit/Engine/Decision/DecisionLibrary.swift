import Foundation

/// The decision models this app knows how to run, and exactly which files each is.
///
/// These are downloaded from their publisher, not from this app's own model
/// host: the address names one fixed revision, and every file is checked
/// against the checksum recorded here, so what runs is what was tested.
public enum DecisionCatalog {
  public struct Entry: Sendable {
    public let alias: String
    public let name: String
    public let summary: String
    /// Where the files are, pinned to one revision.
    let source: URL
    let files: [ModelLibrary.RemoteFile]

    public var downloadSize: Int64 { files.reduce(0) { $0 + $1.size } }
  }

  public static let defaultAlias = "d1-2b"
  public static let entries: [Entry] = [
    Entry(
      alias: "d1-2b", name: "Liquid d1-2B",
      summary:
        "Looks at each image and answers a filter step with yes or no. Much more accurate than matching by description, and much slower: about a third of a second per image. About 2.2 GB to download, and about 3.3 GB of memory while it runs.",
      source: URL(
        string:
          "https://huggingface.co/LiquidAI/d1-2B-MLX-8bit/resolve/3247d0483b11e5da31fa10e7979c23252fbe3580"
      )!,
      files: [
        .init(
          path: "config.json", size: 3_651,
          sha256: "17b7fcbf4aa7d64366979d439c9651aa71390785742f6ef53b49a5268dabb91e"),
        .init(
          path: "calibration.json", size: 4_924,
          sha256: "e534464458f485d800fe6cc896ac241590bbc8cd54f5af08f7b3064b0d884d69"),
        .init(
          path: "LICENSE", size: 10_574,
          sha256: "4d28ca14dedc0b3d0fcc2b3339f0e79931faa33874f3d24f522183a8fc70068c"),
        .init(
          path: "tokenizer.json", size: 17_908_258,
          sha256: "a39eed58008cbcbc09e5b629b81338a654269c64cd13348aaa6090f4db75c7e7"),
        .init(
          path: "model.safetensors", size: 2_216_067_578,
          sha256: "b88f8e9e2c90597d9f913d52a9d2f9fff4d5338e47ea07ca8ab4e774f5ae4869"),
      ])
  ]

  public static func entry(_ alias: String) -> Entry? {
    entries.first { $0.alias == alias }
  }
}

/// Where decision models are kept on this Mac, and how they get there.
public struct DecisionLibrary: Sendable {
  /// What a folder must hold to be a usable model.
  static let requiredFiles = ["config.json", D1DecisionModel.tokenizerFile, D1DecisionModel.weightsFile]

  public let installDirectory: URL
  /// The models on offer; tests pass small stand-ins.
  let catalog: [DecisionCatalog.Entry]

  public init(installDirectory: URL) {
    self.init(installDirectory: installDirectory, catalog: DecisionCatalog.entries)
  }

  init(installDirectory: URL, catalog: [DecisionCatalog.Entry]) {
    self.installDirectory = installDirectory
    self.catalog = catalog
  }

  private func entry(_ alias: String) -> DecisionCatalog.Entry? {
    catalog.first { $0.alias == alias }
  }

  /// The folder holding a complete copy of the model, if there is one.
  public func directory(for alias: String) -> URL? {
    let directory = installDirectory.appendingPathComponent(alias)
    let complete = Self.requiredFiles.allSatisfy {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
    return complete ? directory : nil
  }

  public func models() -> [ModelInfo] {
    catalog.map { entry in
      ModelInfo(
        alias: entry.alias, id: entry.alias, name: entry.name, family: "mlx",
        summary: entry.summary, isDefault: entry.alias == DecisionCatalog.defaultAlias,
        installed: directory(for: entry.alias) != nil, available: true, availabilityMessage: "",
        size: ModelLibrary.size(of: installDirectory.appendingPathComponent(entry.alias)),
        source: ModelSource(downloadBase: entry.source))
    }
  }

  public func remove(_ alias: String) throws {
    guard entry(alias) != nil else {
      throw EngineError.failed("Unknown model: \(alias)")
    }
    let directory = installDirectory.appendingPathComponent(alias)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  public func install(
    _ alias: String, onProgress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void
  ) async throws {
    guard let entry = entry(alias) else {
      throw EngineError.failed("Unknown model: \(alias)")
    }
    do {
      try await ModelLibrary.download(
        entry.files, from: entry.source, name: entry.name, alias: alias,
        into: installDirectory, onProgress: onProgress
      ) { staging in
        // The settings must be ones this app's model code can run.
        _ = try D1Config.load(from: staging)
      }
    } catch let error as EngineError {
      throw error
    } catch where Task.isCancelled {
      throw EngineError.cancelled
    } catch {
      throw EngineError.failed(
        "Could not download \(entry.name). Check your internet connection and try again.")
    }
  }
}
