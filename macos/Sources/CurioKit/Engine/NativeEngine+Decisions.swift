import Foundation

/// Filter steps answered by the decision model: it looks at each image and
/// says how likely "yes" is. Slow, so every answer is kept (`DecisionStore`).
extension NativeEngine {
  public func decisions(
    folder: URL, model alias: String, paths: [String], questions: [String], asking: Bool,
    onProgress: @escaping ProgressHandler
  ) async throws -> DecisionScores {
    guard !questions.isEmpty, !paths.isEmpty else {
      return .empty(model: alias, questions: questions)
    }
    // Nothing has been asked in this folder yet: do not create its answer file just to look.
    if !asking, !FileManager.default.fileExists(atPath: DecisionStore.location(in: folder).path) {
      return DecisionScores(model: alias, questions: questions, answers: [:], unanswered: paths)
    }
    let store = try DecisionStore(folder: folder)
    defer { store.close() }
    let key = Self.answersKey(for: alias)
    let known = try questions.map { try store.answers(model: key, question: $0) }
    // Checking every file's date takes a while in a large folder; not on the engine's own time.
    let survey = await Task.detached {
      Self.survey(paths, in: folder, questions: questions.count, known: known)
    }.value
    var answers = survey.answers
    var unreadable = survey.unreadable
    let waiting = survey.waiting
    guard asking, !waiting.isEmpty else {
      return DecisionScores(
        model: alias, questions: questions, answers: answers, unanswered: waiting.map(\.path),
        unreadable: unreadable)
    }

    let name = DecisionCatalog.entry(alias)?.name ?? alias
    onProgress(EngineProgress("Loading \(name)", estimate: .start))
    decidingWith[alias, default: 0] += 1
    defer {
      let left = (decidingWith[alias] ?? 1) - 1
      decidingWith[alias] = left > 0 ? left : nil
      scheduleIdleUnload()
    }
    let model = try await decisionModel(alias)
    var estimator = RateProgressEstimator()
    var unanswered: [String] = []
    for (done, image) in waiting.enumerated() {
      try Self.checkCancelled()
      onProgress(
        EngineProgress(
          URL(fileURLWithPath: image.path).lastPathComponent,
          estimate: estimator.at(done: Double(done), of: Double(waiting.count)),
          current: done, total: waiting.count, unit: .images))
      let asked = image.missing.map { questions[$0] }
      var own = answers[image.path] ?? [Double?](repeating: nil, count: questions.count)
      do {
        let probabilities = try await model.decide(
          image: URL(fileURLWithPath: image.path), questions: asked)
        for (index, probability) in zip(image.missing, probabilities) { own[index] = probability }
        try store.save(
          model: key, path: image.relative, modified: image.modified, questions: asked,
          probabilities: probabilities)
      } catch let failure as ImagePreprocessor.Failure {
        guard failure.isPermanent else {
          // Could not be read just now (a drive asleep, a file mid-copy): ask again next time.
          unanswered.append(image.path)
          continue
        }
        // Not a picture this Mac can read: remembered, so it is not tried on every run.
        try store.save(
          model: key, path: image.relative, modified: image.modified, questions: asked,
          probabilities: nil)
        unreadable.append(image.path)
        answers[image.path] = nil
        continue
      }
      answers[image.path] = own
    }
    onProgress(
      EngineProgress(
        "Every image has been looked at", estimate: .done, current: waiting.count,
        total: waiting.count, unit: .images))
    return DecisionScores(
      model: alias, questions: questions, answers: answers, unanswered: unanswered,
      unreadable: unreadable)
  }

  /// Names the answers a model has given, as kept on disk: each model's are
  /// its own. The number changes whenever the same image and question could
  /// get a different answer from it: new question wording around the user's
  /// text, a different picture size, a different checkpoint.
  static func answersKey(for alias: String) -> String { "\(alias)/1" }

  struct Waiting: Sendable {
    let path: String
    let relative: String
    let modified: Double
    /// Indices of the questions this image has no current answer to.
    let missing: [Int]
  }

  /// Sorts `paths` into what is already answered, what cannot be read, and what is waiting.
  nonisolated static func survey(
    _ paths: [String], in folder: URL, questions: Int, known: [[String: DecisionStore.Answer]]
  ) -> (answers: [String: [Double?]], unreadable: [String], waiting: [Waiting]) {
    let root = folder.standardizedFileURL.path
    var answers: [String: [Double?]] = [:]
    var unreadable: [String] = []
    var waiting: [Waiting] = []
    for path in paths {
      let relative = relativePath(of: path, in: root)
      let modified = modificationTime(of: path)
      var own = [Double?](repeating: nil, count: questions)
      var missing: [Int] = []
      var couldNotBeRead = false
      for index in 0..<questions {
        // An answer about an earlier version of the file says nothing about this one.
        if let answer = known[index][relative], answer.modified == modified {
          own[index] = answer.probability
          couldNotBeRead = couldNotBeRead || answer.probability == nil
        } else {
          missing.append(index)
        }
      }
      if couldNotBeRead {
        // True of the file whatever the question, so it is not asked the others.
        unreadable.append(path)
        continue
      }
      if missing.count < questions { answers[path] = own }
      // A file that has gone since the folder was read is not waiting for anything.
      if !missing.isEmpty, let modified {
        waiting.append(Waiting(path: path, relative: relative, modified: modified, missing: missing))
      }
    }
    return (answers, unreadable, waiting)
  }

  /// The decision model, loading it if needed; one load serves every waiting request.
  ///
  /// Only one is in memory at a time: each takes gigabytes, and the smaller
  /// one exists for Macs that cannot spare more. So a different model is let
  /// go of before this one is read, and refused while it is still answering.
  private func decisionModel(_ alias: String) async throws -> any DecisionModel {
    while let pending = loadingDecision {
      if pending.alias == alias { return try await pending.task.value }
      _ = await pending.task.result
      // Its owner clears it too, but may not have run yet; without this the wait would spin.
      if loadingDecision?.id == pending.id { loadingDecision = nil }
    }
    if let loadedDecision, loadedDecision.alias == alias { return loadedDecision.model }
    // The caller has counted itself under `alias`; anything else is another model at work.
    guard decidingWith.keys.allSatisfy({ $0 == alias }) else {
      throw EngineError.busy(
        "Another model is looking at images. Let it finish or stop it, then try again.")
    }
    if loadedDecision != nil {
      loadedDecision = nil
      D1DecisionModel.releaseBuffers()
    }
    let loader = loadDecisionModel
    let id = UUID()
    let task = Task { try await loader(alias) }
    loadingDecision = (id, alias, task)
    defer { if loadingDecision?.id == id { loadingDecision = nil } }
    let model = try await task.value
    loadedDecision = (alias, model)
    return model
  }

  /// Lets go of the decision model and the GPU memory it was using.
  func forgetDecisionModel() {
    guard deciding == 0, loadedDecision != nil else { return }
    loadedDecision = nil
    D1DecisionModel.releaseBuffers()
  }

  private static func relativePath(of path: String, in root: String) -> String {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return standardized.hasPrefix(prefix) ? String(standardized.dropFirst(prefix.count)) : standardized
  }

  private static func modificationTime(of path: String) -> Double? {
    let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey])
    return values?.contentModificationDate?.timeIntervalSince1970
  }
}
