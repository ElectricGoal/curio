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
  /// The step's permanent number, shown as "#3": given once, kept through
  /// reordering, so a trace keeps pointing at the same node. 0 until assigned.
  public var number: Int
  public var action: Action
  public var text: String
  public var strictness: Strictness
  /// The decision model that looks at each image for this step, or nil to
  /// match the description against the album's search index instead.
  /// `defaultModel` follows the one chosen in Settings; an alias pins one.
  public var model: String?

  /// A step's model when it follows the decision model chosen in Settings.
  public static let defaultModel = "default"

  /// Whether a decision model looks at each image for this step. Slower and
  /// more accurate than matching the description against the search index.
  public var careful: Bool {
    get { model != nil }
    set { model = newValue ? (model ?? Self.defaultModel) : nil }
  }

  public init(
    id: UUID = UUID(), number: Int = 0, action: Action, text: String,
    strictness: Strictness = .balanced, careful: Bool = false, model: String? = nil
  ) {
    self.id = id
    self.number = number
    self.action = action
    self.text = text
    self.strictness = strictness
    self.model = model ?? (careful ? Self.defaultModel : nil)
  }

  private enum CodingKeys: String, CodingKey { case id, number, action, text, strictness, model, careful }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    number = try values.decodeIfPresent(Int.self, forKey: .number) ?? 0
    action = try values.decode(Action.self, forKey: .action)
    text = try values.decode(String.self, forKey: .text)
    strictness = try values.decode(Strictness.self, forKey: .strictness)
    // Steps saved before each could pick its model: "careful" meant the chosen one.
    let wasCareful = try values.decodeIfPresent(Bool.self, forKey: .careful) ?? false
    model = try values.decodeIfPresent(String.self, forKey: .model)
      ?? (wasCareful ? Self.defaultModel : nil)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(number, forKey: .number)
    try values.encode(action, forKey: .action)
    try values.encode(text, forKey: .text)
    try values.encode(strictness, forKey: .strictness)
    try values.encodeIfPresent(model, forKey: .model)
  }

  /// Gives numbers to steps that have none (saved before numbers existed, or
  /// just added), after the highest already given, in the chain's order.
  public static func numbered(_ steps: [FilterStep]) -> [FilterStep] {
    var next = (steps.map(\.number).max() ?? 0) + 1
    return steps.map { step in
      guard step.number == 0 else { return step }
      var numbered = step
      numbered.number = next
      next += 1
      return numbered
    }
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

/// What one step decided about one image, and why: the unit of a trace.
public struct FilterVerdict: Equatable, Sendable {
  public enum Evidence: Equatable, Sendable {
    /// The step has no words yet, so it let everything through.
    case inactive
    /// Matched against the search index: how much better than "a photo" the
    /// description fits, and how much the step's strictness needs.
    case description(lead: Float, needed: Float)
    /// The decision model's answer: how sure it is the image fits, and how sure it must be.
    case model(alias: String, yes: Double, needed: Double)
    /// A model step whose model has not looked at this image (or cannot read
    /// it), so the description decided for now.
    case notLookedAt(alias: String, unreadable: Bool, lead: Float, needed: Float)
  }

  public let step: UUID
  /// Whether the image fits the step's description.
  public let matched: Bool
  /// Whether it went on to the next step.
  public let kept: Bool
  public let evidence: Evidence
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
  /// For each image, what every step it reached decided, in order. Its last
  /// verdict is where it left the chain, unless it made it to the result.
  public let verdicts: [String: [FilterVerdict]]

  public var result: [String] { stages.last?.remaining ?? all }

  /// An image's way through the chain: what each step it reached decided.
  public func trace(of path: String) -> [FilterVerdict] { verdicts[path] ?? [] }

  /// One decision model's answers, as for a chain whose model steps all use
  /// it: steps following the default are taken to mean that model.
  public init(
    steps: [FilterStep], scores: PromptScores, decisions: DecisionScores?,
    among: Set<String>? = nil
  ) {
    let resolved = steps.map { step -> FilterStep in
      guard let decisions, step.model == FilterStep.defaultModel else { return step }
      var step = step
      step.model = decisions.model
      return step
    }
    self.init(
      steps: resolved, scores: scores, answers: decisions.map { [$0.model: $0] } ?? [:], among: among)
  }

  /// Runs `steps` over images scored against `baseline` first, then one prompt
  /// per active step, in order. With `among`, images not in it (moved or
  /// deleted since indexing) are left out from the start.
  ///
  /// A model step goes by its own model's answer in `answers` (keyed by model)
  /// for each image that has one, and by the description for the rest. Steps
  /// following `FilterStep.defaultModel` must be resolved to a model first.
  public init(
    steps: [FilterStep], scores: PromptScores, answers: [String: DecisionScores] = [:],
    among: Set<String>? = nil
  ) {
    let width = scores.prompts
    let rows = scores.paths.indices
    let base = rows.map { scores.scores[$0 * width] }
    var column = 1
    var current = rows.filter { among?.contains(scores.paths[$0]) ?? true }
    let all = current.map { scores.paths[$0] }
    var stages: [Stage] = []
    var verdicts: [String: [FilterVerdict]] = [:]
    for step in steps {
      guard step.isActive else {
        stages.append(Stage(remaining: current.map { scores.paths[$0] }, dropped: []))
        for row in current {
          verdicts[scores.paths[row], default: []].append(
            FilterVerdict(step: step.id, matched: false, kept: true, evidence: .inactive))
        }
        continue
      }
      let needed = step.strictness.lead
      let index = column
      let confidence = step.strictness.confidence
      let decisions = step.model.flatMap { answers[$0] }
      let asked = decisions?.questions.firstIndex(of: step.question)
      let unreadable = Set(decisions?.unreadable ?? [])
      var kept: [Int] = []
      var dropped: [Int] = []
      var unchecked: [Int] = []
      for row in current {
        let path = scores.paths[row]
        let lead = scores.scores[row * width + index] - base[row]
        let evidence: FilterVerdict.Evidence
        let matched: Bool
        if let alias = step.model {
          if let asked, let yes = decisions?.answers[path]?[asked] {
            evidence = .model(alias: alias, yes: yes, needed: confidence)
            matched = yes >= confidence
          } else {
            let cannotRead = unreadable.contains(path)
            if !cannotRead { unchecked.append(row) }
            evidence = .notLookedAt(alias: alias, unreadable: cannotRead, lead: lead, needed: needed)
            matched = lead >= needed
          }
        } else {
          evidence = .description(lead: lead, needed: needed)
          matched = lead >= needed
        }
        let stays = step.action == .keep ? matched : !matched
        if stays { kept.append(row) } else { dropped.append(row) }
        verdicts[path, default: []].append(
          FilterVerdict(step: step.id, matched: matched, kept: stays, evidence: evidence))
      }
      stages.append(
        Stage(
          remaining: kept.map { scores.paths[$0] }, dropped: dropped.map { scores.paths[$0] },
          unchecked: unchecked.map { scores.paths[$0] }))
      current = kept
      column += 1
    }
    self.all = all
    self.stages = stages
    self.verdicts = verdicts
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
