import AppKit
import CurioKit
import SwiftUI

/// Engine-backed tasks: index status, indexing, models.
extension Studio {
  /// How long a finished task's full bar stays on screen.
  static var completionHold = Duration.milliseconds(600)
  /// How long the first status check may take before the wait is explained.
  static var engineStartPatience = Duration.seconds(5)

  // MARK: - Running a visible task

  /// Runs one piece of engine work as the visible activity. Returns nil when
  /// it fails or is cancelled; failures are shown to the user.
  func perform<Response: Sendable>(
    _ kind: Activity.Kind,
    _ work: @escaping @Sendable (@escaping ProgressHandler) async throws -> Response
  ) async -> Response? {
    guard activity == nil else { return nil }
    let id = UUID().uuidString
    activity = Activity(id: id, kind: kind, startedAt: Date())
    status = kind.title + "…"
    let task = Task {
      try await work { [weak self] progress in
        Task { @MainActor in self?.apply(progress, to: id) }
      }
    }
    // Cancelling the activity cancels this task; the engine stops at its next safe point.
    cancelCurrentActivity = { task.cancel() }
    defer {
      activity = nil
      cancelCurrentActivity = nil
    }
    do {
      let response = try await task.value
      // Let the bar be seen full before it is replaced by the result.
      if let current = activity, current.id == id {
        activity = current.finished()
        try? await Task.sleep(for: Studio.completionHold)
      }
      return response
    } catch EngineError.cancelled, is CancellationError {
      status = "Cancelled"
    } catch {
      status = "Needs attention"
      alert = AlertMessage(title: kind.failureTitle, message: error.localizedDescription)
    }
    return nil
  }

  private func apply(_ progress: EngineProgress, to id: String) {
    guard let current = activity, current.id == id else { return }
    activity = current.applying(progress, now: Date())
  }

  func cancelActivity() {
    guard let current = activity, current.kind.canCancel, !current.isCancelling else { return }
    activity = current.cancelling()
    cancelCurrentActivity?()
  }

  // MARK: - Index status

  /// Asks the engine how much of the folder is searchable. With
  /// `preparingSearch`, also loads the model so the first search is fast.
  func refreshIndexStatus(preparingSearch: Bool = false) {
    guard let folder else { return }
    let generation = folderGeneration
    engineProblem = nil
    let slowStart = Task {
      // Reading a folder on a drive macOS guards can wait on a privacy prompt.
      try? await Task.sleep(for: Studio.engineStartPatience)
      guard !Task.isCancelled, generation == folderGeneration, indexStatus == nil else { return }
      status = "Checking the index… If macOS asks for access to a drive, choose Allow."
    }
    Task {
      defer { slowStart.cancel() }
      do {
        let latest = try await engine.status(folder: folder)
        guard generation == folderGeneration else { return }
        indexStatus = latest
        if status.hasPrefix("Checking the index") { status = Format.images(library.count) }
        if preparingSearch, latest.indexed, !latest.needsRebuild { await prepareSearch(in: folder) }
        guard generation == folderGeneration else { return }
        refreshCurationIfStale()
        if page == .filter || filterRun != nil { runFilter(immediately: true) }
      } catch {
        // Browsing still works without the index, but say why search does not.
        guard generation == folderGeneration else { return }
        indexStatus = nil
        engineProblem = EngineDiagnosis.message(for: error)
        status = "Search is unavailable"
      }
    }
  }

  private func prepareSearch(in folder: URL) async {
    if models.isEmpty { await loadModels() }
    guard activity == nil, let alias = indexStatus?.model, isInstalled(alias) else { return }
    let generation = folderGeneration
    let before = status
    status = "Preparing search…"
    try? await engine.prepare(folder: folder)
    if generation == folderGeneration, status == "Preparing search…" { status = before }
  }

  // MARK: - Indexing

  /// Indexes new and changed images, or replaces the index when `rebuild` is set.
  func indexFolder(rebuild: Bool = false) {
    guard let folder, activity == nil, !isPreparingIndex else { return }
    liveSearch?.cancel()
    // Holds the folder steady across the awaits below (a model check, maybe a
    // download), before the index itself becomes the visible activity.
    isPreparingIndex = true
    let generation = folderGeneration
    Task {
      // Loading the list first also replaces a remembered model that no longer exists.
      if models.isEmpty { await loadModels() }
      // An index this version cannot use is replaced, not updated.
      let rebuild = rebuild || indexNeedsRebuild
      // An update continues with the index's own model; a rebuild adopts the selection.
      let existing = indexStatus?.indexed == true ? indexStatus?.model : nil
      let alias = rebuild ? selectedModel : existing ?? selectedModel
      let ready = await ensureInstalled(alias)
      isPreparingIndex = false
      guard ready, generation == folderGeneration else { return }
      notice = nil
      // Lets the engine estimate the time from the first moment, before it has scanned.
      let expected =
        rebuild || indexStatus?.indexed != true
        ? library.count : indexStatus?.pending ?? library.count
      let engine = engine
      let response = await perform(rebuild ? .rebuilding : .indexing) { progress in
        try await engine.index(
          folder: folder, model: alias, rebuild: rebuild, expected: expected, onProgress: progress)
      }
      guard generation == folderGeneration else { return }
      if let response {
        notice = Studio.notice(for: response)
        status = response.cancelled ? "Indexing paused" : "Ready to search"
        duplicates = nil  // found against the previous index
        if rebuild {
          clearSearch()
          curation = nil  // labelled with the old index; redone below
        }
      }
      refreshIndexStatus()
    }
  }

  private static func notice(for response: IndexResponse) -> Notice {
    if response.cancelled {
      return Notice(
        style: .paused, title: "Indexing paused",
        message:
          "\(Format.images(response.count)) searchable so far · \(Format.count(response.remaining)) to go. Your progress is saved."
      )
    }
    var parts = ["\(Format.images(response.count)) searchable"]
    if response.added > 0 { parts.append("\(Format.count(response.added)) added") }
    if response.removed > 0 { parts.append("\(Format.count(response.removed)) removed") }
    if response.skipped > 0 { parts.append("\(Format.count(response.skipped)) could not be read") }
    if response.added == 0, response.removed == 0 { parts.append("already up to date") }
    return Notice(style: .success, title: "Index ready", message: parts.joined(separator: " · "))
  }

  // MARK: - Models

  func loadModels() async {
    do {
      let response = try await engine.models()
      models = response.models
      modelStorage = response.storage
      decisionModels = response.decision
      adoptUsableModel()
      adoptInstalledDecisionModel()
    } catch {
      status = "Could not load the model list."
    }
  }

  /// Keeps the selection on a model that exists and can actually be used.
  private func adoptUsableModel() {
    guard !models.isEmpty else { return }
    let chosen = models.first { $0.alias == selectedModel }
    // Still fine: it is installed, or it can be fetched when needed.
    if let chosen, chosen.installed || chosen.available { return }
    // The remembered model was removed, or this copy of the app cannot get it.
    let fallback =
      models.first { $0.installed } ?? models.first { $0.isDefault && $0.available }
      ?? models.first { $0.available }
    if let fallback, fallback.alias != selectedModel { selectModel(fallback.alias) }
  }

  /// Careful steps go to a decision model that is on this Mac when the chosen
  /// one is not: the only one downloaded is the one meant.
  private func adoptInstalledDecisionModel() {
    let chosen = decisionModels.first { $0.alias == selectedDecisionModel }
    if chosen?.installed == true { return }
    if let installed = decisionModels.first(where: \.installed) {
      selectDecisionModel(installed.alias)
      // Said, so the change is not a surprise on the Filter page.
      status = "Careful filter steps now use \(installed.name)"
    } else if chosen == nil, let fallback = decisionModels.first(where: \.isDefault) ?? decisionModels.first {
      // The remembered model is no longer one the app knows.
      selectDecisionModel(fallback.alias)
    }
  }

  func refreshModels() {
    Task { await loadModels() }
  }

  func isInstalled(_ alias: String) -> Bool {
    (models + decisionModels).first { $0.alias == alias }?.installed ?? false
  }

  func downloadModel(_ alias: String) {
    Task { _ = await download(alias) }
  }

  func deleteModel(_ alias: String) {
    Task {
      let engine = engine
      let change = await perform(.removingModel) { _ in try await engine.deleteModel(alias) }
      if change != nil { status = "Model removed" }
      await loadModels()
    }
  }

  /// Makes sure a model's files are on disk, downloading them if necessary.
  private func ensureInstalled(_ alias: String) async -> Bool {
    if models.isEmpty { await loadModels() }
    guard let model = models.first(where: { $0.alias == alias }) else {
      return true  // not in the list: let the engine explain
    }
    if model.installed { return true }
    guard model.available else {
      alert = AlertMessage(title: "\(model.name) is not available", message: model.availabilityMessage)
      return false
    }
    return await download(alias)
  }

  private func download(_ alias: String) async -> Bool {
    let name = (models + decisionModels).first { $0.alias == alias }?.name ?? alias
    let engine = engine
    let change = await perform(.downloading(modelName: name)) { progress in
      try await engine.downloadModel(alias, onProgress: progress)
    }
    await loadModels()
    if change != nil { status = "\(name) is ready" }
    return change != nil
  }
}
