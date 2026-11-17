import Foundation

/// Whether the app is shown light, dark, or as macOS is set.
public enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
  case system, light, dark

  public var id: String { rawValue }
  public var label: String { rawValue.capitalized }
}

/// Settings remembered between launches.
public struct Preferences: Codable, Equatable, Sendable {
  public static let defaultModel = "mobileclip-s4"
  public static let thumbnailRange: ClosedRange<Double> = 110...320

  public var model: String
  public var folder: String?
  /// The albums: folders the user added, in the order they were added. (Stored
  /// under its first name, from when it held recently opened folders.)
  public var recentFolders: [String]
  public var thumbnailSize: Double
  public var sort: PhotoSort
  /// Smart albums, by the words they match.
  public var albums: [String]
  /// The filter chain, kept between launches.
  public var filterSteps: [FilterStep]
  public var appearance: Appearance
  /// The decision model careful filter steps use.
  public var decisionModel: String

  public init(
    model: String = Preferences.defaultModel, folder: String? = nil,
    recentFolders: [String] = [], thumbnailSize: Double = 180, sort: PhotoSort = .name,
    albums: [String] = [], filterSteps: [FilterStep] = [], appearance: Appearance = .system,
    decisionModel: String = DecisionCatalog.defaultAlias
  ) {
    self.model = model
    self.folder = folder
    self.recentFolders = recentFolders
    self.thumbnailSize = thumbnailSize
    self.sort = sort
    self.albums = albums
    self.filterSteps = filterSteps
    self.appearance = appearance
    self.decisionModel = decisionModel
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
    let storedAppearance = try? values.decodeIfPresent(String.self, forKey: .appearance)
    appearance = storedAppearance.flatMap(Appearance.init) ?? .system
    let storedDecision = try? values.decodeIfPresent(String.self, forKey: .decisionModel)
    decisionModel = storedDecision.flatMap { $0.isEmpty ? nil : $0 } ?? fallback.decisionModel
  }

  /// A copy with `path` as the current folder, added to the albums if it is new.
  /// Albums keep the order they were added in: opening one does not move it.
  public func opening(folder path: String) -> Preferences {
    var copy = self
    copy.folder = path
    if !recentFolders.contains(path) { copy.recentFolders = recentFolders + [path] }
    return copy
  }

  /// A copy with `path` dropped from the albums (and as the current folder).
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
