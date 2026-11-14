import Foundation

/// Progress reported while a request runs.
public struct EngineProgress: Sendable, Equatable {
  public enum Unit: String, Sendable { case images, bytes }

  public let message: String
  /// How much of the thing being counted is done ("128 of 1,024 images").
  public let current: Int?
  public let total: Int?
  public let unit: Unit?
  /// Share of the whole task done, 0–1, across all of its phases.
  public let fraction: Double?
  /// Estimated seconds remaining.
  public let eta: Double?
  /// How far the bar may advance before the next report (the end of this phase).
  public let ceiling: Double?

  public init(
    message: String, current: Int? = nil, total: Int? = nil, unit: Unit? = nil,
    fraction: Double? = nil, eta: Double? = nil, ceiling: Double? = nil
  ) {
    self.message = message
    self.current = current
    self.total = total
    self.unit = unit
    self.fraction = fraction
    self.eta = eta
    self.ceiling = ceiling
  }

  /// Share of the counted items done; a fallback when no overall position is sent.
  public var countFraction: Double? {
    guard let current, let total, total > 0 else { return nil }
    return min(1, max(0, Double(current) / Double(total)))
  }
}

public enum EngineError: Error, Equatable, LocalizedError {
  case cancelled
  /// The engine is doing something that this request would disturb.
  case busy(String)
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .cancelled: return "Cancelled"
    case .busy(let message), .failed(let message): return message
    }
  }
}

/// Turns an engine failure into something a person can act on.
public enum EngineDiagnosis {
  public static let permissionHint =
    "macOS is blocking access to a drive this app needs. Choose Allow if it asks, or turn on ImageSearch under System Settings › Privacy & Security › Files and Folders, then try again."

  public static func message(for error: Error) -> String {
    let description = error.localizedDescription
    return isPermissionProblem(description) ? permissionHint : description
  }

  /// A denied privacy prompt surfaces as an ordinary "not permitted" file error.
  static func isPermissionProblem(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return lowered.contains("operation not permitted") || lowered.contains("permission denied")
      || lowered.contains("don’t have permission") || lowered.contains("don't have permission")
  }
}

// MARK: - Results

public struct ImageRecord: Decodable, Sendable, Equatable {
  public let path: String
  public let name: String
  public let size: Int64
  public let modified: Double
  public let similarity: Double?
  public let keep: Bool?

  public init(path: String, name: String, size: Int64, modified: Double, similarity: Double? = nil, keep: Bool? = nil) {
    self.path = path
    self.name = name
    self.size = size
    self.modified = modified
    self.similarity = similarity
    self.keep = keep
  }
}

public struct SearchResponse: Decodable, Sendable, Equatable {
  public let images: [ImageRecord]
  public let total: Int
  public let model: String

  public init(images: [ImageRecord], total: Int, model: String) {
    self.images = images
    self.total = total
    self.model = model
  }
}

public struct IndexResponse: Decodable, Sendable, Equatable {
  public let count: Int
  public let added: Int
  public let skipped: Int
  public let removed: Int
  public let remaining: Int
  public let cancelled: Bool
  public let model: String
  public let modelName: String
  public let seconds: Double

  public init(count: Int, added: Int, skipped: Int, removed: Int, remaining: Int, cancelled: Bool, model: String, modelName: String, seconds: Double) {
    self.count = count
    self.added = added
    self.skipped = skipped
    self.removed = removed
    self.remaining = remaining
    self.cancelled = cancelled
    self.model = model
    self.modelName = modelName
    self.seconds = seconds
  }
}

public struct IndexStatus: Decodable, Sendable, Equatable {
  public let indexed: Bool
  public let total: Int
  public let count: Int
  public let pending: Int
  public let missing: Int
  public let unreadable: Int
  public let model: String?
  public let modelName: String?
  /// False when the index was built with a model the app no longer offers.
  public let modelAvailable: Bool?
  public let updatedAt: Double?
  /// Why the index must be rebuilt, in words for the user, when it must be.
  public let rebuildReason: String?

  public init(
    indexed: Bool, total: Int, count: Int, pending: Int, missing: Int, unreadable: Int,
    model: String?, modelName: String?, modelAvailable: Bool?, updatedAt: Double?,
    rebuildReason: String? = nil
  ) {
    self.indexed = indexed
    self.total = total
    self.count = count
    self.pending = pending
    self.missing = missing
    self.unreadable = unreadable
    self.model = model
    self.modelName = modelName
    self.modelAvailable = modelAvailable
    self.updatedAt = updatedAt
    self.rebuildReason = rebuildReason
  }

  /// The index exists but cannot be searched or updated until it is rebuilt.
  public var needsRebuild: Bool { indexed && modelAvailable == false }
}

public struct ModelInfo: Decodable, Sendable, Equatable, Identifiable {
  public let alias: String
  public let id: String
  public let name: String
  public let family: String
  public let summary: String
  public let isDefault: Bool
  public let installed: Bool
  public let available: Bool
  public let availabilityMessage: String
  public let size: Int64

  public init(
    alias: String, id: String, name: String, family: String, summary: String, isDefault: Bool,
    installed: Bool, available: Bool, availabilityMessage: String, size: Int64
  ) {
    self.alias = alias
    self.id = id
    self.name = name
    self.family = family
    self.summary = summary
    self.isDefault = isDefault
    self.installed = installed
    self.available = available
    self.availabilityMessage = availabilityMessage
    self.size = size
  }

  enum CodingKeys: String, CodingKey {
    case alias, id, name, family, summary, installed, available, availabilityMessage, size
    case isDefault = "default"
  }
}

public struct ModelsResponse: Decodable, Sendable, Equatable {
  public let models: [ModelInfo]
  public let storage: String

  public init(models: [ModelInfo], storage: String) {
    self.models = models
    self.storage = storage
  }
}

public struct ModelChange: Decodable, Sendable, Equatable {
  public let model: String
  public let installed: Bool

  public init(model: String, installed: Bool) {
    self.model = model
    self.installed = installed
  }
}

public struct WarmResponse: Decodable, Sendable, Equatable {
  public let model: String
}

public struct DuplicateGroup: Decodable, Sendable, Equatable {
  public let kind: String
  public let similarity: Double
  public let files: [ImageRecord]

  public var isExact: Bool { kind == "exact" }

  public init(kind: String, similarity: Double, files: [ImageRecord]) {
    self.kind = kind
    self.similarity = similarity
    self.files = files
  }
}

public struct DuplicatesResponse: Decodable, Sendable, Equatable {
  public let groups: [DuplicateGroup]
  public let redundant: Int
  public let reclaimable: Int64
  public let threshold: Double

  public init(groups: [DuplicateGroup], redundant: Int, reclaimable: Int64, threshold: Double) {
    self.groups = groups
    self.redundant = redundant
    self.reclaimable = reclaimable
    self.threshold = threshold
  }
}
