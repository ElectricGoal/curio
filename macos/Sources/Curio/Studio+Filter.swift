import AppKit
import CurioKit
import SwiftUI

/// The filter chain: steps that keep or remove images by description, run in
/// order over the folder, and a copy or move of what is left.
extension Studio {
  /// Long enough that typing a description does not re-run the chain per key.
  private static let filterDelay = Duration.milliseconds(350)

  /// Ready-made steps for the "Add a suggested step" menu.
  static let suggestedSteps: [(action: FilterStep.Action, text: String)] = [
    (.keep, "portrait photos of a person"),
    (.keep, "a product on a plain white background"),
    (.keep, "photos of people"),
    (.keep, "landscape photos"),
    // Short, concrete wording works best: long lists of qualities match almost anything.
    (.remove, "a blurry, out of focus photo"),
    (.remove, "screenshots"),
    (.remove, "photos of text or documents"),
  ]

  // MARK: - Editing the chain

  func addStep(_ action: FilterStep.Action, text: String = "") {
    let step = FilterStep(action: action, text: text)
    filterSteps.append(step)
    filterFocus = step.id
    stepsChanged()
  }

  func updateStep(_ id: UUID, _ change: (inout FilterStep) -> Void) {
    guard let index = filterSteps.firstIndex(where: { $0.id == id }) else { return }
    var step = filterSteps[index]
    change(&step)
    guard step != filterSteps[index] else { return }
    filterSteps[index] = step
    filterFocus = id
    stepsChanged()
  }

  func removeStep(_ id: UUID) {
    filterSteps.removeAll { $0.id == id }
    if filterFocus == id { filterFocus = nil }
    stepsChanged()
  }

  func moveStep(_ id: UUID, by offset: Int) {
    guard let index = filterSteps.firstIndex(where: { $0.id == id }),
      filterSteps.indices.contains(index + offset)
    else { return }
    filterSteps.swapAt(index, index + offset)
    stepsChanged()
  }

  func focusFilter(on id: UUID?) {
    filterFocus = id
    filterShowsRemoved = false
    updateFilterPreview()
  }

  private func stepsChanged() {
    updatePreferences { $0.filterSteps = filterSteps }
    runFilter()
  }

  // MARK: - Running

  /// Re-runs the chain over the folder's index, shortly after the last change.
  func runFilter(immediately: Bool = false) {
    filterTask?.cancel()
    filterGeneration += 1
    let generation = filterGeneration
    // While the folder is still being read there is nothing to filter yet; the
    // index check that follows the read runs the chain again.
    guard let folder, !isScanning, hasIndex, !indexNeedsRebuild else {
      filterRun = nil
      isFiltering = false
      updateFilterPreview()
      return
    }
    let steps = filterSteps
    let prompts = [FilterRun.baseline] + steps.filter(\.isActive).map(\.prompt)
    let questions = Studio.questions(for: steps)
    let present = Set(library.map(\.path))
    let engine = engine
    isFiltering = true
    filterProblem = nil
    filterTask = Task {
      if !immediately { try? await Task.sleep(for: Studio.filterDelay) }
      guard !Task.isCancelled, generation == filterGeneration else { return }
      defer { if generation == filterGeneration { isFiltering = false } }
      do {
        let scores = try await engine.scores(folder: folder, prompts: prompts)
        // What the decision model has already said; nothing is asked of it here.
        var decisions: DecisionScores?
        if !questions.isEmpty {
          do {
            decisions = try await engine.decisions(
              folder: folder, paths: scores.paths.filter(present.contains), questions: questions,
              asking: false, onProgress: { _ in })
          } catch {
            // The chain still runs by description; say why the saved answers are not in it.
            if generation == filterGeneration { status = EngineDiagnosis.message(for: error) }
          }
        }
        let answered = decisions
        let run = await Task.detached {
          FilterRun(steps: steps, scores: scores, decisions: answered, among: present)
        }.value
        guard generation == filterGeneration else { return }
        filterRun = run
        updateFilterPreview()
      } catch {
        guard generation == filterGeneration else { return }
        filterProblem = EngineDiagnosis.message(for: error)
      }
    }
  }

  // MARK: - Careful steps

  /// The decision model that answers careful steps, as the model list describes it.
  var decisionModel: ModelInfo? {
    decisionModels.first { $0.isDefault } ?? decisionModels.first
  }

  private static func questions(for steps: [FilterStep]) -> [String] {
    var seen: Set<String> = []
    return steps.filter { $0.isActive && $0.careful }.map(\.question).filter { seen.insert($0).inserted }
  }

  /// Images the step at `index` judged by description because the decision
  /// model has not looked at them yet.
  func uncheckedCount(at index: Int) -> Int {
    guard let run = filterRun, run.stages.indices.contains(index) else { return 0 }
    return run.stages[index].unchecked.count
  }

  /// Has the decision model look at the images reaching this step that it has
  /// not seen yet. Each answer is kept, so stopping part-way loses nothing.
  func lookAtImages(for id: UUID) {
    guard let folder, activity == nil, !isFiltering, let run = filterRun,
      let index = filterSteps.firstIndex(where: { $0.id == id }), run.stages.indices.contains(index),
      filterSteps[index].careful, filterSteps[index].isActive
    else { return }
    let paths = run.stages[index].unchecked
    let question = filterSteps[index].question
    guard !paths.isEmpty else { return }
    let engine = engine
    Task {
      if decisionModels.isEmpty { await loadModels() }
      guard let model = decisionModel, model.installed else {
        alert = AlertMessage(
          title: "A model is needed first",
          message: "Careful steps use \(decisionModel?.name ?? "a decision model"). Download it in Settings.")
        return
      }
      let answered = await perform(.deciding) { progress in
        try await engine.decisions(
          folder: folder, paths: paths, questions: [question], asking: true, onProgress: progress)
      }
      if let answered {
        let skipped = answered.unanswered.count + answered.unreadable.count
        status =
          "Looked at \(Format.images(paths.count - skipped))"
          + (skipped == 0 ? "" : " · \(Format.count(skipped)) could not be read")
      }
      // Also after stopping part-way: the answers given so far count.
      runFilter(immediately: true)
    }
  }

  /// How many images go into the step at `index`, and how many it takes out.
  func filterCounts(at index: Int) -> (input: Int, dropped: Int)? {
    guard let run = filterRun, run.stages.indices.contains(index) else { return nil }
    let input = index == 0 ? run.all.count : run.stages[index - 1].remaining.count
    return (input, run.stages[index].dropped.count)
  }

  func updateFilterPreview() {
    guard let run = filterRun else {
      filterPreview = []
      return
    }
    let paths: [String]
    if let id = filterFocus, let index = filterSteps.firstIndex(where: { $0.id == id }),
      run.stages.indices.contains(index)
    {
      paths = filterShowsRemoved ? run.stages[index].dropped : run.stages[index].remaining
    } else if filterShowsRemoved {
      let kept = Set(run.result)
      paths = run.all.filter { !kept.contains($0) }
    } else {
      paths = run.result
    }
    let byPath = Dictionary(library.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    filterPreview = paths.compactMap { byPath[$0] }
  }

  // MARK: - Output

  func chooseExportFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    panel.message = "Choose where the filtered images go."
    if panel.runModal() == .OK, let url = panel.url { exportFolder = url }
  }

  /// Names and creates a new folder for the result, next to the open one by default.
  func createExportFolder() {
    let panel = NSSavePanel()
    panel.title = "New Folder"
    panel.prompt = "Create"
    panel.message = "Name a new folder for the filtered images."
    panel.nameFieldLabel = "Folder name:"
    panel.nameFieldStringValue = "\(folder?.lastPathComponent ?? "Images") – filtered"
    panel.canCreateDirectories = true
    // Saving over an existing folder is not offered as "Replace": it is reused below.
    panel.showsTagField = false
    panel.directoryURL = folder?.deletingLastPathComponent()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      // Reuses a folder that already exists by that name; never replaces it.
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      exportFolder = url
    } catch {
      alert = AlertMessage(title: "The folder could not be created", message: error.localizedDescription)
    }
  }

  /// Copies or moves the chain's result into the chosen folder.
  func exportFiltered() {
    guard let destination = exportFolder, let run = filterRun, let folder, activity == nil else {
      return
    }
    guard destination.standardizedFileURL.path != folder.standardizedFileURL.path else {
      alert = AlertMessage(
        title: "Choose another folder", message: "The filtered images are already in this folder.")
      return
    }
    let paths = run.result
    guard !paths.isEmpty else { return }
    let mode = exportMode
    Task {
      let outcome = await perform(.exporting(mode)) { progress in
        FileExport.run(paths, to: destination, mode: mode, isCancelled: { Task.isCancelled }) {
          done, total in
          progress(
            EngineProgress(
              message: "Into \(destination.lastPathComponent)", current: done, total: total,
              unit: .images, fraction: Double(done) / Double(max(1, total))))
        }
      }
      guard let outcome else { return }
      let verb = mode == .copy ? "Copied" : "Moved"
      status = "\(verb) \(Format.images(outcome.done.count)) to \(destination.lastPathComponent)"
        + (outcome.cancelled ? " before stopping" : "")
      if !outcome.failed.isEmpty {
        alert = AlertMessage(
          title: "Some images could not be \(mode == .copy ? "copied" : "moved")",
          message: outcome.failed.prefix(5).map { URL(fileURLWithPath: $0).lastPathComponent }
            .joined(separator: "\n"))
      }
      if mode == .move, !outcome.done.isEmpty {
        // They have left this folder: drop them now, then re-read it and its index.
        let gone = Set(outcome.done)
        library = library.filter { !gone.contains($0.path) }
        curation = curation?.removing(gone)
        runFilter(immediately: true)
        reloadLibrary()
      }
      if !outcome.done.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
    }
  }
}
