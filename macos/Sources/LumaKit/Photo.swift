import Foundation

/// An image file shown in the library or in search results.
public struct Photo: Identifiable, Hashable, Sendable {
  public let path: String
  public let name: String
  public let size: Int64
  public let modified: Date
  /// Similarity to the current query, present only for search results.
  public let score: Double?

  public var id: String { path }
  public var url: URL { URL(fileURLWithPath: path) }

  public init(path: String, name: String, size: Int64, modified: Date, score: Double? = nil) {
    self.path = path
    self.name = name
    self.size = size
    self.modified = modified
    self.score = score
  }

  public init(_ record: ImageRecord) {
    self.init(
      path: record.path, name: record.name, size: record.size,
      modified: Date(timeIntervalSince1970: record.modified), score: record.similarity)
  }
}

public enum PhotoSort: String, Codable, CaseIterable, Sendable, Identifiable {
  case name, newest, oldest, largest

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .name: return "Name"
    case .newest: return "Newest first"
    case .oldest: return "Oldest first"
    case .largest: return "Largest first"
    }
  }

  public func sorted(_ photos: [Photo]) -> [Photo] {
    switch self {
    case .name:
      return photos.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    case .newest:
      return photos.sorted { ($0.modified, $1.path) > ($1.modified, $0.path) }
    case .oldest:
      return photos.sorted { ($0.modified, $0.path) < ($1.modified, $1.path) }
    case .largest:
      return photos.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }
  }
}

/// An image file as the index sees it.
public struct ScannedFile: Equatable, Sendable {
  public let url: URL
  /// Path relative to the folder, with forward slashes: the index's key.
  public let relativePath: String
  /// Modification time in seconds since 1970.
  public let modified: Double
  public let size: Int64
}

/// Finds the image files in a folder, the same set the engine indexes.
public enum LibraryScanner {
  public static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp", "gif",
  ]

  public static func isImage(_ url: URL) -> Bool {
    imageExtensions.contains(url.pathExtension.lowercased())
  }

  /// Every image under `folder`, keyed for the index, in a stable order.
  public static func files(in folder: URL) -> [ScannedFile] {
    (walk(folder) ?? []).sorted { $0.relativePath < $1.relativePath }
  }

  /// Walks `folder`, skipping hidden files. Returns nil if the task is cancelled.
  public static func scan(
    _ folder: URL, reportEvery step: Int = 200,
    onProgress: (@Sendable (Int) -> Void)? = nil
  ) -> [Photo]? {
    walk(folder, reportEvery: step, onProgress: onProgress)?.map {
      Photo(
        path: $0.url.path, name: $0.url.lastPathComponent, size: $0.size,
        modified: Date(timeIntervalSince1970: $0.modified))
    }
  }

  /// The one place the folder is enumerated, so the app's list and the index
  /// always agree on which files exist and how their paths are spelled.
  private static func walk(
    _ folder: URL, reportEvery step: Int = 200,
    onProgress: (@Sendable (Int) -> Void)? = nil
  ) -> [ScannedFile]? {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    // Relative URLs come from the enumerator itself, so paths are right even
    // when the folder was reached through a symbolic link (/var → /private/var).
    guard
      let files = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .producesRelativePathURLs])
    else { return [] }
    var found: [ScannedFile] = []
    while let url = files.nextObject() as? URL {
      guard isImage(url), let values = try? url.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true
      else { continue }
      found.append(
        ScannedFile(
          url: folder.appendingPathComponent(url.relativePath), relativePath: url.relativePath,
          modified: (values.contentModificationDate ?? .distantPast).timeIntervalSince1970,
          size: Int64(values.fileSize ?? 0)))
      if found.count % step == 0 {
        if Task.isCancelled { return nil }
        onProgress?(found.count)
      }
    }
    return Task.isCancelled ? nil : found
  }
}
