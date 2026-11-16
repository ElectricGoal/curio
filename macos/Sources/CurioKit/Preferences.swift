import Foundation

/// Settings remembered between launches.
public struct Preferences: Codable, Equatable, Sendable {
  public static let defaultModel = "mobileclip-s4"
  public static let recentLimit = 8
  public static let thumbnailRange: ClosedRange<Double> = 110...320

  public var model: String
  public var folder: String?
  public var recentFolders: [String]
  public var thumbnailSize: Double
  public var sort: PhotoSort
  /// Smart albums, by the words they match.
  public var albums: [String]
  /// The filter chain, kept between launches.
  public var filterSteps: [FilterStep]

  public init(
    model: String = Preferences.defaultModel, folder: String? = nil,
    recentFolders: [String] = [], thumbnailSize: Double = 180, sort: PhotoSort = .name,
    albums: [String] = [], filterSteps: [FilterStep] = []
  ) {
    self.model = model
    self.folder = folder
    self.recentFolders = recentFolders
    self.thumbnailSize = thumbnailSize
    self.sort = sort
    self.albums = albums
    self.filterSteps = filterSteps
  }

  /// Tolerates files written by earlier versions, which stored fewer keys.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = Preferences()
    model = try values.decodeIfPresent(String.self, forKey: .model) ?? fallback.model
    let storedFolder = try values.decodeIfPresent(String.self, forKey: .folder)
    folder = storedFolder.flatMap { $0.isEmpty ? nil : $0 }
    recentFolders = try values.decodeIfPresent([String].self, forKey: .recentFolders) ?? []
    let size = try values.decodeIfPresent(Double.self, forKey: .thumbnailSize)
    thumbnailSize = (size ?? fallback.thumbnailSize).clamped(to: Preferences.thumbnailRange)
    let storedSort = try values.decodeIfPresent(String.self, forKey: .sort)
    sort = storedSort.flatMap(PhotoSort.init) ?? fallback.sort
    albums = try values.decodeIfPresent([String].self, forKey: .albums) ?? []
    filterSteps = (try? values.decodeIfPresent([FilterStep].self, forKey: .filterSteps)) ?? []
  }

  /// A copy with `path` as the current folder and at the front of the recents.
  public func opening(folder path: String) -> Preferences {
    var copy = self
    copy.folder = path
    copy.recentFolders = Array(
      ([path] + recentFolders.filter { $0 != path }).prefix(Preferences.recentLimit))
    return copy
  }

  /// A copy with `path` dropped from the recents (and as the current folder).
  public func forgetting(folder path: String) -> Preferences {
    var copy = self
    copy.recentFolders = recentFolders.filter { $0 != path }
    if copy.folder == path { copy.folder = nil }
    return copy
  }
}

public struct PreferencesStore: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  /// Stored preferences, or defaults when the file is missing or unreadable.
  public func load() -> Preferences {
    guard let data = try? Data(contentsOf: url),
      let preferences = try? JSONDecoder().decode(Preferences.self, from: data)
    else { return Preferences() }
    return preferences
  }

  public func save(_ preferences: Preferences) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(preferences).write(to: url, options: .atomic)
  }
}

extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
