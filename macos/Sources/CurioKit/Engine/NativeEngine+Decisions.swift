import Foundation

/// Filter steps answered by the decision model: it looks at each image and
/// says how likely "yes" is. Slow, so every answer is kept (`DecisionStore`).
extension NativeEngine {
  /// The model that answers; there is one.
  static let decisionAlias = DecisionCatalog.defaultAlias

  public func decisions(
    folder: URL, paths: [String], questions: [String], asking: Bool,
    onProgress: @escaping ProgressHandler
  ) async throws -> DecisionScores {
    let alias = Self.decisionAlias
    guard !questions.isEmpty, !paths.isEmpty else {
      return .empty(model: alias, questions: questions)
    }
    // Nothing has been asked in this folder yet: do not create its answer file just to look.
    if !asking, !FileManager.default.fileExists(atPath: DecisionStore.location(in: folder).path) {
      return DecisionScores(model: alias, questions: questions, answers: [:], unanswered: paths)
    }
    let store = try DecisionStore(folder: folder)
    defer { store.close() }
    let key = Self.answersKey
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
    deciding += 1
    defer {
      deciding -= 1
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

  /// Names the answers kept on disk. The number changes whenever the same
  /// image and question could get a different answer: new question wording
  /// around the user's text, a different picture size, a different checkpoint.
  static let answersKey = "\(decisionAlias)/1"

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
  private func decisionModel(_ alias: String) async throws -> any DecisionModel {
    if let loadedDecision, loadedDecision.alias == alias { return loadedDecision.model }
    if let pending = loadingDecision, pending.alias == alias { return try await pending.task.value }
    let loader = loadDecisionModel
    let task = Task { try await loader(alias) }
    loadingDecision = (alias, task)
    defer { if loadingDecision?.alias == alias { loadingDecision = nil } }
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
