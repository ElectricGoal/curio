import Foundation

/// How one model has performed on this Mac.
public struct ModelTiming: Codable, Equatable, Sendable {
  /// Used until a model has been timed here.
  public static let untimed = ModelTiming(loadSeconds: 3, imagesPerSecond: 30)

  public var loadSeconds: Double
  public var imagesPerSecond: Double

  public init(loadSeconds: Double, imagesPerSecond: Double) {
    self.loadSeconds = loadSeconds
    self.imagesPerSecond = imagesPerSecond
  }
}

/// Per-model timings remembered between launches, so a time estimate exists
/// from the first second of the next run.
public struct TimingStore: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  private func read() -> [String: ModelTiming] {
    guard let data = try? Data(contentsOf: url),
      let timings = try? JSONDecoder().decode([String: ModelTiming].self, from: data)
    else { return [:] }
    return timings
  }

  public func timing(for alias: String) -> ModelTiming {
    read()[alias] ?? .untimed
  }

  /// Remembers a measurement. Failing to save one never fails the task it timed.
  public func record(_ alias: String, loadSeconds: Double? = nil, imagesPerSecond: Double? = nil) {
    var timings = read()
    var timing = timings[alias] ?? .untimed
    if let loadSeconds, loadSeconds > 0 { timing.loadSeconds = loadSeconds }
    if let imagesPerSecond, imagesPerSecond > 0 { timing.imagesPerSecond = imagesPerSecond }
    timings[alias] = timing
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(timings) else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }
}

/// Where a task stands on its single 0–100% bar.
public struct ProgressEstimate: Equatable, Sendable {
  /// Share of the whole task done, 0–1.
  public let fraction: Double
  /// Seconds remaining, or nil when there is nothing to base one on.
  public let eta: Double?
  /// How far the bar may glide before the next report: the end of this phase.
  public let ceiling: Double

  public static let start = ProgressEstimate(fraction: 0, eta: nil, ceiling: 0.02)
  public static let done = ProgressEstimate(fraction: 1, eta: 0, ceiling: 1)
}

/// Tracks an index run through scan → load → embed → save.
///
/// Phases differ wildly in length, so the common unit is time: the position
/// is `elapsed ÷ (elapsed + estimated remaining)`. It never moves backwards;
/// a phase that overruns holds the bar still instead.
public struct IndexProgressEstimator {
  static let scanSecondsPerImage = 0.0005
  static let minimumScanSeconds = 0.2
  static let saveSeconds = 0.3
  /// A rate measured over fewer images, or less time, is too noisy to trust.
  public static let minimumImagesForRate = 16
  static let minimumSecondsForRate = 1.0
  /// The bar only reaches 100% when the task has actually finished.
  static let maximumUnfinished = 0.99

  private let timing: ModelTiming
  private let expected: Int?
  private let now: () -> Date
  private let started: Date
  private var loadRemaining: Double
  private var embeddingStartedAt: Date?
  private var processed = 0
  private var floor = 0.0

  public init(
    timing: ModelTiming, modelLoaded: Bool, expected: Int?, now: @escaping () -> Date = Date.init
  ) {
    self.timing = timing
    self.expected = expected
    self.now = now
    started = now()
    loadRemaining = modelLoaded ? 0 : timing.loadSeconds
  }

  /// The run has just begun. `expected` is the app's count of images to do.
  public mutating func scanning() -> ProgressEstimate {
    guard let expected else { return .start }
    let scan = max(Self.minimumScanSeconds, Double(expected) * Self.scanSecondsPerImage)
    let later = expected > 0 ? loadRemaining + embedSeconds(expected) + Self.saveSeconds : Self.saveSeconds
    let position = place(phase: scan, later: later)
    floor = 0  // this is the starting line: the bar begins at exactly zero
    return ProgressEstimate(fraction: 0, eta: position.eta, ceiling: position.ceiling)
  }

  public mutating func loading(total: Int) -> ProgressEstimate {
    place(phase: loadRemaining, later: embedSeconds(total) + Self.saveSeconds)
  }

  public mutating func embeddingStarted() {
    loadRemaining = 0
    embeddingStartedAt = now()
  }

  public mutating func embedding(processed: Int, total: Int) -> ProgressEstimate {
    self.processed = processed
    return place(phase: embedSeconds(total - processed), later: Self.saveSeconds)
  }

  public mutating func saving() -> ProgressEstimate {
    place(phase: Self.saveSeconds, later: 0)
  }

  /// Images per second in this run, once it is worth trusting.
  public var measuredRate: Double? {
    guard let embeddingStartedAt, processed >= Self.minimumImagesForRate else { return nil }
    let elapsed = now().timeIntervalSince(embeddingStartedAt)
    return elapsed >= Self.minimumSecondsForRate ? Double(processed) / elapsed : nil
  }

  private func embedSeconds(_ images: Int) -> Double {
    Double(max(0, images)) / (measuredRate ?? timing.imagesPerSecond)
  }

  private mutating func place(phase: Double, later: Double) -> ProgressEstimate {
    let elapsed = now().timeIntervalSince(started)
    let remaining = max(0, phase) + max(0, later)
    let whole = elapsed + remaining
    let fraction = max(floor, min(whole > 0 ? elapsed / whole : 0, 1))
    let phaseEnd = whole > 0 ? (elapsed + max(0, phase)) / whole : fraction
    floor = fraction
    return ProgressEstimate(
      fraction: fraction, eta: remaining,
      ceiling: max(fraction, min(phaseEnd, Self.maximumUnfinished)))
  }
}

/// Progress for work counted in one unit (bytes, rows) at a steady pace.
public struct RateProgressEstimator {
  private let now: () -> Date
  private let started: Date
  private var floor = 0.0

  public init(now: @escaping () -> Date = Date.init) {
    self.now = now
    started = now()
  }

  /// `finishing` reserves the tail of the bar for work after the counted part.
  public mutating func at(done: Double, of total: Double, finishing: Double = 0) -> ProgressEstimate {
    let share = (1 - finishing) * (total > 0 ? min(done, total) / total : 0)
    let fraction = max(floor, min(share, 1))
    floor = fraction
    let elapsed = now().timeIntervalSince(started)
    let eta = fraction > 0 && elapsed > 0 ? elapsed / fraction * (1 - fraction) : nil
    return ProgressEstimate(fraction: fraction, eta: eta, ceiling: fraction)
  }
}

extension EngineProgress {
  /// A progress report carrying a position on the bar.
  public init(
    _ message: String, estimate: ProgressEstimate, current: Int? = nil, total: Int? = nil,
    unit: Unit? = nil
  ) {
    self.init(
      message: message, current: current, total: total, unit: unit, fraction: estimate.fraction,
      eta: estimate.eta, ceiling: estimate.ceiling)
  }
}
