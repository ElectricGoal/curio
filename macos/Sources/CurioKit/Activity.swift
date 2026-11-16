import Foundation

/// A long-running engine task the user can watch (and usually cancel).
public struct Activity: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case indexing
    case rebuilding
    case downloading(modelName: String)
    case removingModel
    case findingDuplicates
    /// Copying or moving filtered images to another folder.
    case exporting(FileExport.Mode)
    /// The decision model looking at each image for a careful filter step.
    case deciding

    public var title: String {
      switch self {
      case .indexing: return "Indexing your collection"
      case .rebuilding: return "Rebuilding the search index"
      case .downloading(let name): return "Downloading \(name)"
      case .removingModel: return "Removing model"
      case .findingDuplicates: return "Looking for duplicates"
      case .exporting(let mode): return mode == .copy ? "Copying images" : "Moving images"
      case .deciding: return "Looking at each image"
      }
    }

    public var failureTitle: String {
      switch self {
      case .indexing, .rebuilding: return "Indexing did not finish"
      case .downloading: return "The download did not finish"
      case .removingModel: return "The model could not be removed"
      case .findingDuplicates: return "Could not look for duplicates"
      case .exporting(let mode): return mode == .copy ? "The images could not be copied" : "The images could not be moved"
      case .deciding: return "The images could not all be looked at"
      }
    }

    /// Indexing stops at the next batch and keeps its progress; everything
    /// else is stopped by restarting the engine.
    public var cancelsCooperatively: Bool {
      switch self {
      // A careful step stops after the image in hand and keeps the answers it has.
      case .indexing, .rebuilding, .deciding: return true
      case .downloading, .removingModel, .findingDuplicates, .exporting: return false
      }
    }

    /// Whether the task reads or writes the open folder's index.
    public var usesFolder: Bool {
      switch self {
      case .indexing, .rebuilding, .findingDuplicates, .exporting, .deciding: return true
      case .downloading, .removingModel: return false
      }
    }

    public var canCancel: Bool { self != .removingModel }
  }

  /// A phase this far past its expected end is worth telling the user about.
  static let overdueGrace: TimeInterval = 3

  public let id: String
  public let kind: Kind
  public let message: String
  public let current: Int?
  public let total: Int?
  public let unit: EngineProgress.Unit?
  /// Share of the whole task done at `updatedAt`, 0–1.
  public let fraction: Double
  /// Seconds the engine expected to remain at `updatedAt`.
  public let eta: Double?
  /// How far the bar may advance on its own before the engine reports again.
  public let ceiling: Double
  public let updatedAt: Date
  public let isCancelling: Bool
  public let isFinished: Bool

  public init(id: String, kind: Kind, startedAt: Date) {
    self.init(
      id: id, kind: kind, message: "Getting ready…", current: nil, total: nil, unit: nil,
      fraction: 0, eta: nil, ceiling: 0, updatedAt: startedAt, isCancelling: false,
      isFinished: false)
  }

  private init(
    id: String, kind: Kind, message: String, current: Int?, total: Int?,
    unit: EngineProgress.Unit?, fraction: Double, eta: Double?, ceiling: Double, updatedAt: Date,
    isCancelling: Bool, isFinished: Bool
  ) {
    self.id = id
    self.kind = kind
    self.message = message
    self.current = current
    self.total = total
    self.unit = unit
    self.fraction = fraction
    self.eta = eta
    self.ceiling = ceiling
    self.updatedAt = updatedAt
    self.isCancelling = isCancelling
    self.isFinished = isFinished
  }

  // MARK: - Position and time

  /// Seconds after `updatedAt` at which the bar reaches its ceiling.
  private var glideDuration: TimeInterval {
    guard let eta, eta > 0, fraction < 1 else { return 0 }
    return (ceiling - fraction) / (1 - fraction) * eta
  }

  /// Where the bar should be right now, 0–1.
  ///
  /// Between engine reports the bar keeps moving at the pace the estimate
  /// implies, so it never sits still through a long phase, but it stops at the
  /// phase boundary rather than running ahead of the work.
  public func progress(at now: Date) -> Double {
    if isFinished { return 1 }
    guard let eta, eta > 0, fraction < 1 else { return fraction }
    let elapsed = max(0, now.timeIntervalSince(updatedAt))
    return min(ceiling, fraction + (1 - fraction) * elapsed / eta)
  }

  /// Estimated seconds left, or nil when there is nothing to base one on.
  public func secondsRemaining(at now: Date) -> Double? {
    if isFinished { return 0 }
    guard let eta else { return nil }
    let elapsed = max(0, now.timeIntervalSince(updatedAt))
    return max(0, eta - min(elapsed, glideDuration))
  }

  /// The current phase has clearly outlasted its estimate.
  public func isOverdue(at now: Date) -> Bool {
    guard !isFinished, eta != nil else { return false }
    return now.timeIntervalSince(updatedAt) > glideDuration + Self.overdueGrace
  }

  // MARK: - Updates

  /// A copy reflecting the latest progress event. The bar never moves backwards.
  public func applying(_ progress: EngineProgress, now: Date) -> Activity {
    // Reports are delivered asynchronously; one that lands after the end is stale.
    guard !isFinished else { return self }
    let shown = self.progress(at: now)
    let reported = progress.fraction ?? progress.countFraction ?? shown
    let position = min(1, max(shown, reported))
    return Activity(
      id: id, kind: kind, message: progress.message, current: progress.current,
      total: progress.total, unit: progress.unit, fraction: position, eta: progress.eta,
      ceiling: max(position, min(1, progress.ceiling ?? position)), updatedAt: now,
      isCancelling: isCancelling, isFinished: false)
  }

  public func cancelling() -> Activity {
    Activity(
      id: id, kind: kind, message: message, current: current, total: total, unit: unit,
      fraction: fraction, eta: eta, ceiling: ceiling, updatedAt: updatedAt, isCancelling: true,
      isFinished: isFinished)
  }

  /// The task completed: the bar is full.
  public func finished() -> Activity {
    Activity(
      id: id, kind: kind, message: "Done", current: current, total: total, unit: unit,
      fraction: 1, eta: 0, ceiling: 1, updatedAt: updatedAt, isCancelling: false,
      isFinished: true)
  }

  // MARK: - Text

  /// "128 of 1,024 images · 37% · about 2 min left".
  public func detail(now: Date) -> String {
    var parts: [String] = []
    if let current, let total, !isFinished {
      switch unit {
      case .bytes: parts.append("\(Format.bytes(Int64(current))) of \(Format.bytes(Int64(total)))")
      case .images, nil: parts.append("\(Format.count(current)) of \(Format.images(total))")
      }
    }
    parts.append("\(Int(progress(at: now) * 100))%")
    if isFinished || isCancelling { return parts.joined(separator: " · ") }
    if isOverdue(at: now) {
      parts.append("taking longer than usual…")
    } else if let seconds = secondsRemaining(at: now) {
      parts.append(Format.remaining(seconds))
    } else {
      parts.append("estimating time…")
    }
    return parts.joined(separator: " · ")
  }
}
