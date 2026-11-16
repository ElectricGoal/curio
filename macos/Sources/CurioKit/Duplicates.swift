import Foundation

/// A group of images that are copies of each other, with one chosen to keep.
public struct DuplicateSet: Identifiable, Equatable, Sendable {
  public let id: Int
  public let isExact: Bool
  public let similarity: Double
  public let photos: [Photo]
  public let keeperPath: String
  /// The photo Curio judged the best of similar shots, when it chose one that way.
  public let bestShotPath: String?

  public init(
    id: Int, isExact: Bool, similarity: Double, photos: [Photo], keeperPath: String,
    bestShotPath: String? = nil
  ) {
    self.id = id
    self.isExact = isExact
    self.similarity = similarity
    self.photos = photos
    self.keeperPath = keeperPath
    self.bestShotPath = bestShotPath
  }

  /// Builds a set from the engine's group; nil if it lacks a keeper or a copy.
  public init?(id: Int, group: DuplicateGroup) {
    guard group.files.count > 1,
      let keeper = group.files.first(where: { $0.keep == true }) ?? group.files.first
    else { return nil }
    self.init(
      id: id, isExact: group.isExact, similarity: group.similarity,
      photos: group.files.map(Photo.init), keeperPath: keeper.path, bestShotPath: group.bestShot)
  }

  /// The copies that would be removed.
  public var extras: [Photo] { photos.filter { $0.path != keeperPath } }

  public var label: String {
    isExact ? "Identical files" : "Look alike · \(Format.score(similarity)) similar"
  }

  /// A copy that keeps a different photo.
  public func keeping(_ path: String) -> DuplicateSet {
    guard photos.contains(where: { $0.path == path }) else { return self }
    return DuplicateSet(
      id: id, isExact: isExact, similarity: similarity, photos: photos, keeperPath: path,
      bestShotPath: bestShotPath)
  }

  /// A copy without the given files; nil once no duplicate remains.
  public func removing(_ paths: Set<String>) -> DuplicateSet? {
    let remaining = photos.filter { !paths.contains($0.path) }
    guard remaining.count > 1 else { return nil }
    let keeper = remaining.contains { $0.path == keeperPath } ? keeperPath : remaining[0].path
    return DuplicateSet(
      id: id, isExact: isExact, similarity: similarity, photos: remaining, keeperPath: keeper,
      bestShotPath: bestShotPath.flatMap { paths.contains($0) ? nil : $0 })
  }
}

public struct DuplicateReport: Equatable, Sendable {
  public let sets: [DuplicateSet]

  public init(sets: [DuplicateSet]) {
    self.sets = sets
  }

  public init(_ response: DuplicatesResponse) {
    self.init(
      sets: response.groups.enumerated().compactMap { DuplicateSet(id: $0.offset, group: $0.element) })
  }

  public var extras: [Photo] { sets.flatMap(\.extras) }
  public var reclaimableBytes: Int64 { extras.reduce(0) { $0 + $1.size } }

  public func keeping(_ path: String, in setID: Int) -> DuplicateReport {
    DuplicateReport(sets: sets.map { $0.id == setID ? $0.keeping(path) : $0 })
  }

  public func removing(_ paths: Set<String>) -> DuplicateReport {
    DuplicateReport(sets: sets.compactMap { $0.removing(paths) })
  }
}

/// How aggressively to match duplicates.
public enum DuplicateMode: String, CaseIterable, Identifiable, Sendable {
  case exact, nearIdentical, similar

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .exact: return "Identical files"
    case .nearIdentical: return "Near-identical"
    case .similar: return "Similar shots"
    }
  }

  public var explanation: String {
    switch self {
    case .exact: return "Byte-for-byte copies, even under different names."
    case .nearIdentical: return "The same picture saved again — resized, re-compressed or converted."
    case .similar: return "Bursts and close variations. The best shot is suggested; review before removing."
    }
  }

  public var threshold: Double {
    switch self {
    case .exact: return 1.0
    case .nearIdentical: return 0.98
    case .similar: return 0.94
    }
  }
}

public enum FileTrash {
  public struct Outcome: Equatable, Sendable {
    public let trashed: Set<String>
    public let failed: [String]
  }

  /// Moves files to the Trash, where they can be restored with Put Back.
  public static func move(_ paths: [String]) -> Outcome {
    var trashed: Set<String> = []
    var failed: [String] = []
    for path in paths {
      do {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        trashed.insert(path)
      } catch {
        failed.append(path)
      }
    }
    return Outcome(trashed: trashed, failed: failed)
  }
}
