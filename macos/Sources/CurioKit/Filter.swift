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
  }

  public var id: UUID
  public var action: Action
  public var text: String
  public var strictness: Strictness

  public init(id: UUID = UUID(), action: Action, text: String, strictness: Strictness = .balanced) {
    self.id = id
    self.action = action
    self.text = text
    self.strictness = strictness
  }

  /// Steps without words do nothing yet.
  public var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

  /// The description phrased the way CLIP matches best.
  public var prompt: String { Labels.album(text.trimmingCharacters(in: .whitespaces)).prompt }
}

/// What a filter chain did to a folder, stage by stage.
public struct FilterRun: Equatable, Sendable {
  public struct Stage: Equatable, Sendable {
    /// Images still in after this step, in the order they were scored.
    public let remaining: [String]
    /// Images this step took out.
    public let dropped: [String]
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
  public init(steps: [FilterStep], scores: PromptScores, among: Set<String>? = nil) {
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
      let matches = { (row: Int) in scores.scores[row * width + index] - base[row] >= lead }
      let kept = current.filter { step.action == .keep ? matches($0) : !matches($0) }
      let keptSet = Set(kept)
      stages.append(
        Stage(
          remaining: kept.map { scores.paths[$0] },
          dropped: current.filter { !keptSet.contains($0) }.map { scores.paths[$0] }))
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
