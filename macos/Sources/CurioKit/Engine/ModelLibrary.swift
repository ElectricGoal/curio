import CryptoKit
import Foundation

/// The models this app knows how to run.
public enum ModelCatalog {
  public struct Entry: Equatable, Sendable {
    public let alias: String
    public let name: String
    public let summary: String
  }

  public static let defaultAlias = "mobileclip-s4"
  public static let entries: [Entry] = [
    Entry(
      alias: "mobileclip-s4", name: "MobileCLIP-S4 (Apple)",
      summary: "The best search quality. About 890 MB to download."),
    Entry(
      alias: "clip-vit-b32", name: "OpenAI CLIP ViT-B/32",
      summary:
        "Smaller (about 300 MB) and quicker to index, with less accurate results for detailed descriptions."
    ),
  ]

  public static func entry(_ alias: String) -> Entry? {
    entries.first { $0.alias == alias }
  }
}

/// Where converted models live, and how they get there.
///
/// A model can be installed in the app's data folder, shipped inside the app
/// bundle, or downloaded from a host that serves the converted files.
public struct ModelLibrary: Sendable {
  static let listingName = "files.json"
  /// Larger than any model this app offers; a listing claiming more is not believed.
  static let largestDownload: Int64 = 20_000_000_000

  /// One file of a hosted model, as listed in its `files.json`.
  struct RemoteFile: Decodable {
    let path: String
    let size: Int64
    let sha256: String
  }

  /// Models added by the user: downloads and local conversions.
  public let installDirectory: URL
  /// Models shipped inside the app; these cannot be removed.
  public let bundledDirectory: URL?
  /// Base address of hosted models, with one folder per alias; nil when there is none.
  public let remote: URL?

  public init(installDirectory: URL, bundledDirectory: URL? = nil, remote: URL? = nil) {
    self.installDirectory = installDirectory
    self.bundledDirectory = bundledDirectory
    self.remote = remote
  }

  /// The folder holding a usable copy of the model, if there is one.
  public func directory(for alias: String) -> URL? {
    [installDirectory, bundledDirectory].compactMap { $0?.appendingPathComponent(alias) }
      .first { isComplete($0) }
  }

  private func isComplete(_ directory: URL) -> Bool {
    FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(ModelManifest.fileName).path)
  }

  private func isBundled(_ alias: String) -> Bool {
    bundledDirectory.map { isComplete($0.appendingPathComponent(alias)) } ?? false
  }

  public func models() -> [ModelInfo] {
    ModelCatalog.entries.map { entry in
      let directory = directory(for: entry.alias)
      let obtainable = directory != nil || remote != nil
      return ModelInfo(
        alias: entry.alias, id: entry.alias, name: entry.name, family: "coreml",
        summary: entry.summary, isDefault: entry.alias == ModelCatalog.defaultAlias,
        installed: directory != nil, available: obtainable,
        availabilityMessage: obtainable ? "" : Self.notIncluded(entry.alias),
        // Only what the user could free by removing it.
        size: Self.size(of: installDirectory.appendingPathComponent(entry.alias)),
        source: remote.flatMap { ModelSource(downloadBase: $0.appendingPathComponent(entry.alias)) })
    }
  }

  static func notIncluded(_ alias: String) -> String {
    "Not included in this copy of the app. From a source checkout, run “bash scripts/convert-models.sh \(alias)”."
  }

  /// Removes a model the user installed. Models inside the app stay.
  public func remove(_ alias: String) throws {
    guard ModelCatalog.entry(alias) != nil else {
      throw EngineError.failed("Unknown model: \(alias)")
    }
    let directory = installDirectory.appendingPathComponent(alias)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    } else if isBundled(alias) {
      throw EngineError.failed("This model is part of the app and cannot be removed.")
    }
  }

  /// Downloads a hosted model: every listed file is verified against its
  /// checksum, and the model only appears once all of it has arrived.
  public func install(
    _ alias: String, onProgress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void
  ) async throws {
    guard let entry = ModelCatalog.entry(alias) else {
      throw EngineError.failed("Unknown model: \(alias)")
    }
    guard let remote else { throw EngineError.failed(Self.notIncluded(alias)) }
    let base = remote.appendingPathComponent(alias)
    let notValid = EngineError.failed("The download for \(entry.name) is not valid.")
    let listing: [RemoteFile]
    do {
      try Self.checkCancelled()
      let (data, _) = try await URLSession.shared.data(
        from: base.appendingPathComponent(Self.listingName))
      listing = try JSONDecoder().decode([RemoteFile].self, from: data)
    } catch {
      // A cancelled request surfaces as a network error; report it as what it was.
      try Self.checkCancelled()
      if error as? EngineError == .cancelled { throw error }
      throw EngineError.failed(
        "Could not reach the download for \(entry.name). Check your internet connection and try again."
      )
    }
    try await Self.download(
      listing, from: base, name: entry.name, alias: alias, into: installDirectory,
      onProgress: onProgress
    ) { staging in
      guard try ModelManifest.load(from: staging).alias == alias else { throw notValid }
    }
  }

  /// Downloads `listing` from `base` into `directory/alias`: every file is
  /// checked against its size and checksum, `accept` has the last word on the
  /// complete set, and only then does it replace what was there.
  static func download(
    _ listing: [RemoteFile], from base: URL, name: String, alias: String, into directory: URL,
    onProgress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void,
    accept: (URL) throws -> Void
  ) async throws {
    let notValid = EngineError.failed("The download for \(name) is not valid.")
    let damaged = EngineError.failed("The download for \(name) was damaged in transit. Try again.")
    // A listing may come from the network: nothing in it is trusted until checked.
    let sizesAreSane = listing.allSatisfy { (0...Self.largestDownload).contains($0.size) }
    let pathsStayInside = listing.allSatisfy {
      !$0.path.isEmpty && !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..")
    }
    guard !listing.isEmpty, sizesAreSane, pathsStayInside else { throw notValid }
    let total = listing.reduce(Int64(0)) { $0 + $1.size }
    guard total <= Self.largestDownload else { throw notValid }

    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    Self.removeLeftovers(of: alias, in: directory)
    let staging = directory.appendingPathComponent(Self.stagingPrefix(alias) + UUID().uuidString)
    defer { try? manager.removeItem(at: staging) }
    var done: Int64 = 0
    onProgress(0, total)
    for file in listing {
      try Self.checkCancelled()
      let finished = done
      let temporary = try await FileDownload.fetch(base.appendingPathComponent(file.path)) {
        onProgress(finished + $0, total)
      }
      defer { try? manager.removeItem(at: temporary) }
      let received = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
      guard received.map(Int64.init) == file.size,
        try Self.sha256(of: temporary) == file.sha256.lowercased()
      else { throw damaged }
      let destination = staging.appendingPathComponent(file.path)
      try manager.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try manager.moveItem(at: temporary, to: destination)
      done += file.size
      onProgress(done, total)
    }
    try Self.checkCancelled()
    try accept(staging)
    try Self.put(staging, inPlaceOf: directory.appendingPathComponent(alias))
  }

  private static func stagingPrefix(_ alias: String) -> String { ".download-\(alias)-" }
  private static func replacedPrefix(_ alias: String) -> String { ".replaced-\(alias)-" }

  private static func checkCancelled() throws {
    if Task.isCancelled { throw EngineError.cancelled }
  }

  /// Clears what a download of this model left behind if the app quit part-way.
  private static func removeLeftovers(of alias: String, in directory: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names
    where name.hasPrefix(stagingPrefix(alias)) || name.hasPrefix(replacedPrefix(alias)) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  /// Installs `staging` as `destination`. A copy already there is only given
  /// up once the new one is in place, and is put back if that fails.
  private static func put(_ staging: URL, inPlaceOf destination: URL) throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: destination.path) else {
      try manager.moveItem(at: staging, to: destination)
      return
    }
    let aside = destination.deletingLastPathComponent().appendingPathComponent(
      replacedPrefix(destination.lastPathComponent) + UUID().uuidString)
    try manager.moveItem(at: destination, to: aside)
    do {
      try manager.moveItem(at: staging, to: destination)
    } catch {
      try? manager.moveItem(at: aside, to: destination)
      throw error
    }
    try? manager.removeItem(at: aside)
  }

  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func size(of directory: URL) -> Int64 {
    guard
      let files = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return 0 }
    var total: Int64 = 0
    for case let url as URL in files {
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
    }
    return total
  }
}

/// Downloads one file, reporting bytes received and stopping on cancellation.
enum FileDownload {
  static func fetch(_ url: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws -> URL {
    let box = TaskBox()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
          box.observation = nil
          if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            continuation.resume(throwing: cancelled ? EngineError.cancelled : error)
            return
          }
          if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation.resume(
              throwing: EngineError.failed("The download server answered \(http.statusCode)."))
            return
          }
          guard let location else {
            continuation.resume(throwing: EngineError.failed("The download produced no file."))
            return
          }
          // The system deletes `location` when this handler returns, so keep a copy.
          let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("curio-download-" + UUID().uuidString)
          do {
            try FileManager.default.moveItem(at: location, to: kept)
            continuation.resume(returning: kept)
          } catch {
            continuation.resume(throwing: error)
          }
        }
        box.observation = task.progress.observe(\.completedUnitCount) { progress, _ in
          onBytes(progress.completedUnitCount)
        }
        // Started through the box, which cancels it at once if the cancel came first.
        box.start(task)
      }
    } onCancel: {
      box.cancel()
    }
  }

  /// Holds the running download so a cancel reaches it whichever comes first:
  /// the cancel handler can run before the download task even exists.
  private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTask: URLSessionDownloadTask?
    private var storedObservation: NSKeyValueObservation?
    private var isCancelled = false

    func start(_ task: URLSessionDownloadTask) {
      let cancelledAlready = lock.withLock { () -> Bool in
        storedTask = task
        return isCancelled
      }
      task.resume()
      if cancelledAlready { task.cancel() }
    }

    func cancel() {
      let task = lock.withLock { () -> URLSessionDownloadTask? in
        isCancelled = true
        return storedTask
      }
      task?.cancel()
    }
    var observation: NSKeyValueObservation? {
      get { lock.withLock { storedObservation } }
      set { lock.withLock { storedObservation = newValue } }
    }
  }
}
