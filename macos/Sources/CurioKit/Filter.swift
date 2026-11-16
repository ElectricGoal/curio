import Foundation

/// One step of a filter chain: keep or remove the images matching a description.
public struct FilterStep: Codable, Equatable, Identifiable, Sendable {
  public enum Action: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep, remove
    public var id: String { rawValue }
    public var label: String { self == .keep ? "Keep" : "Remove" }
  }

  /// How closely an image must fit the description to count as a match.
  public enum Strictness: String, Codable, CaseIterable, Identifiable, Sendable {
    case loose, balanced, strict
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    // shortcut: measured with MobileCLIP-S4 on sample images (night photos +0.03–0.04,
    // day versions −0.01–−0.03); tune on real libraries and per model if needed.
    /// How much better than plain "a photo" the description must fit an image.
    var lead: Float {
      switch self {
      case .loose: return 0.01
      case .balanced: return 0.02
      case .strict: return 0.035
      }
    }

    // shortcut: set from 83 sample images with d1-2B, where every clear match
    // scored above 0.5 and no clear miss did; tune on real libraries if needed.
    /// How sure the decision model must be that an image fits the description.
    var confidence: Double {
      switch self {
      case .loose: return 0.3
      case .balanced: return 0.5
      case .strict: return 0.8
      }
    }
  }

  public var id: UUID
  public var action: Action
  public var text: String
  public var strictness: Strictness
  /// Whether the decision model looks at each image for this step. Slower and
  /// more accurate than matching the description against the search index.
  public var careful: Bool

  public init(
    id: UUID = UUID(), action: Action, text: String, strictness: Strictness = .balanced,
    careful: Bool = false
  ) {
    self.id = id
    self.action = action
    self.text = text
    self.strictness = strictness
    self.careful = careful
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    action = try values.decode(Action.self, forKey: .action)
    text = try values.decode(String.self, forKey: .text)
    strictness = try values.decode(Strictness.self, forKey: .strictness)
    // Steps saved before careful steps existed are plain ones.
    careful = try values.decodeIfPresent(Bool.self, forKey: .careful) ?? false
  }

  /// Steps without words do nothing yet.
  public var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

  /// The description phrased the way CLIP matches best.
  public var prompt: String { Labels.album(text.trimmingCharacters(in: .whitespaces)).prompt }

  /// The description as a yes/no question for the decision model.
  public var question: String {
    "Does this image match the description “\(text.trimmingCharacters(in: .whitespaces))”?"
  }
}

/// What a filter chain did to a folder, stage by stage.
public struct FilterRun: Equatable, Sendable {
  public struct Stage: Equatable, Sendable {
    /// Images still in after this step, in the order they were scored.
    public let remaining: [String]
    /// Images this step took out.
    public let dropped: [String]
    /// Images a careful step judged by description alone, because the
    /// decision model has not looked at them yet.
    public let unchecked: [String]

    public init(remaining: [String], dropped: [String], unchecked: [String] = []) {
      self.remaining = remaining
      self.dropped = dropped
      self.unchecked = unchecked
    }
  }

  /// Compared with every step: an image matches a description when it fits it
  /// clearly better than this. Works for subjects ("portraits") and qualities
  /// ("blurry", "on a white background") alike.
  public static let baseline = "a photo"

  public let all: [String]
  /// One per step, in order.
  public let stages: [Stage]

  public var result: [String] { stages.last?.remaining ?? all }

  /// Runs `steps` over images scored against `baseline` first, then one prompt
  /// per active step, in order. With `among`, images not in it (moved or
  /// deleted since indexing) are left out from the start.
  ///
  /// A careful step goes by the decision model's answer in `decisions` for
  /// each image that has one, and by the description for the rest.
  public init(
    steps: [FilterStep], scores: PromptScores, decisions: DecisionScores? = nil,
    among: Set<String>? = nil
  ) {
    let width = scores.prompts
    let rows = scores.paths.indices
    let base = rows.map { scores.scores[$0 * width] }
    var column = 1
    var current = rows.filter { among?.contains(scores.paths[$0]) ?? true }
    let all = current.map { scores.paths[$0] }
    var stages: [Stage] = []
    for step in steps {
      guard step.isActive else {
        stages.append(Stage(remaining: current.map { scores.paths[$0] }, dropped: []))
        continue
      }
      let lead = step.strictness.lead
      let index = column
      let confidence = step.strictness.confidence
      let asked = step.careful ? decisions?.questions.firstIndex(of: step.question) : nil
      let verdict = { (row: Int) -> Double? in
        guard let asked, let own = decisions?.answers[scores.paths[row]] else { return nil }
        return own[asked]
      }
      let matches = { (row: Int) -> Bool in
        if let probability = verdict(row) { return probability >= confidence }
        return scores.scores[row * width + index] - base[row] >= lead
      }
      let unreadable = Set(decisions?.unreadable ?? [])
      let unchecked =
        step.careful
        ? current.filter { verdict($0) == nil && !unreadable.contains(scores.paths[$0]) } : []
      let kept = current.filter { step.action == .keep ? matches($0) : !matches($0) }
      let keptSet = Set(kept)
      stages.append(
        Stage(
          remaining: kept.map { scores.paths[$0] },
          dropped: current.filter { !keptSet.contains($0) }.map { scores.paths[$0] },
          unchecked: unchecked.map { scores.paths[$0] }))
      current = kept
      column += 1
    }
    self.all = all
    self.stages = stages
  }
}

/// Copies or moves files into a folder without overwriting anything there.
public enum FileExport {
  public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
    case copy, move
    public var id: String { rawValue }
    public var label: String { self == .copy ? "Copy" : "Move" }
  }

  public struct Outcome: Equatable, Sendable {
    public let done: [String]
    public let failed: [String]
    public let cancelled: Bool
  }

  /// `name.ext`, or `name 2.ext`, `name 3.ext`… whichever is free in `folder`.
  public static func freeName(for name: String, in folder: URL, taken: Set<String>) -> URL {
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var candidate = name
    var number = 2
    while taken.contains(candidate.lowercased())
      || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
    {
      candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
      number += 1
    }
    return folder.appendingPathComponent(candidate)
  }

  /// Stops between files when `isCancelled` says so, keeping what was done.
  public static func run(
    _ paths: [String], to folder: URL, mode: Mode, isCancelled: () -> Bool = { false },
    onProgress: (Int, Int) -> Void = { _, _ in }
  ) -> Outcome {
    var done: [String] = []
    var failed: [String] = []
    // Case-insensitive, like the default macOS file system.
    var taken: Set<String> = []
    for (number, path) in paths.enumerated() {
      if isCancelled() { return Outcome(done: done, failed: failed, cancelled: true) }
      let source = URL(fileURLWithPath: path)
      let target = freeName(for: source.lastPathComponent, in: folder, taken: taken)
      taken.insert(target.lastPathComponent.lowercased())
      do {
        if mode == .copy {
          try FileManager.default.copyItem(at: source, to: target)
        } else {
          try FileManager.default.moveItem(at: source, to: target)
        }
        done.append(path)
      } catch {
        failed.append(path)
      }
      onProgress(number + 1, paths.count)
    }
    return Outcome(done: done, failed: failed, cancelled: false)
  }
}
