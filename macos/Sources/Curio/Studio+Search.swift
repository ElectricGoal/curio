import AppKit
import CurioKit
import SwiftUI

/// Searching, duplicate review and moving files to the Trash.
extension Studio {
  private static let liveSearchDelay = Duration.milliseconds(260)

  // MARK: - Search

  /// Runs the typed query (the Return key or the Search button).
  func submitSearch() {
    liveSearch?.cancel()
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      clearSearch()
      return
    }
    guard checkSearchable(interactive: true), let folder else { return }
    if let reference {
      runSearch(refined(reference, by: text), in: folder)
    } else {
      runSearch(.text(text), in: folder)
    }
  }

  /// Searches as the user types, once the index is ready and nothing else runs.
  func queryEdited() {
    liveSearch?.cancel()
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    // With a reference image, typed words refine it instead of starting a new search.
    if let reference {
      guard SearchRefinement(parsing: text) != shownRefinement,
        checkSearchable(interactive: false)
      else { return }
      liveSearch = Task {
        try? await Task.sleep(for: Studio.liveSearchDelay)
        guard !Task.isCancelled, let folder, self.reference == reference,
          text == query.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        runSearch(refined(reference, by: text), in: folder, interactive: false)
      }
      return
    }
    guard !text.isEmpty else {
      // Emptying the field ends a text search, but must not cancel a search
      // by image (which clears the field itself).
      if (pendingSearch ?? results?.kind) == .text { clearSearch(keepingQuery: true) }
      return
    }
    guard checkSearchable(interactive: false) else { return }
    liveSearch = Task {
      try? await Task.sleep(for: Studio.liveSearchDelay)
      guard !Task.isCancelled, let folder,
        text == query.trimmingCharacters(in: .whitespacesAndNewlines)
      else { return }
      runSearch(.text(text), in: folder, interactive: false)
    }
  }

  func chooseReferenceImage() {
    guard checkSearchable(interactive: true) else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.message = "Choose an image to find similar ones in this folder."
    if panel.runModal() == .OK, let url = panel.url {
      searchSimilar(toImageAt: url.path, named: url.lastPathComponent)
    }
  }

  func searchSimilar(to photo: Photo) {
    searchSimilar(toImageAt: photo.path, named: photo.name)
  }

  func searchSimilar(toImageAt path: String, named name: String) {
    liveSearch?.cancel()
    guard checkSearchable(interactive: true), let folder else { return }
    reference = ReferenceImage(path: path, name: name)
    query = ""
    preview = nil
    page = .library
    runSearch(.image(path: path, name: name, refinement: SearchRefinement()), in: folder)
  }

  private func refined(_ reference: ReferenceImage, by text: String) -> Query {
    .image(path: reference.path, name: reference.name, refinement: SearchRefinement(parsing: text))
  }

  func clearSearch(keepingQuery: Bool = false) {
    liveSearch?.cancel()
    searchGeneration += 1
    cancelSearchInFlight()
    pendingSearch = nil
    isSearching = false
    results = nil
    reference = nil
    shownRefinement = nil
    if !keepingQuery { query = "" }
    if folder != nil, !isScanning { status = Format.images(library.count) }
  }

  /// Explains why search is unavailable. Typing never interrupts with a prompt.
  private func checkSearchable(interactive: Bool) -> Bool {
    guard folder != nil else { return false }
    guard hasIndex else {
      if interactive { needsIndexPrompt = true }
      return false
    }
    guard activity == nil else {
      if interactive { status = "Search is available as soon as the current task finishes." }
      return false
    }
    guard !indexNeedsRebuild else {
      if interactive {
        alert = AlertMessage(
          title: "This folder needs a new index",
          message:
            (indexStatus?.rebuildReason ?? "Its index cannot be used by this version.")
            + " Choose Rebuild Index in the library to search it again."
        )
      }
      return false
    }
    if let alias = indexStatus?.model, !models.isEmpty, !isInstalled(alias) {
      if interactive {
        alert = AlertMessage(
          title: "This index needs a model that is not installed",
          message:
            "Add \(indexStatus?.modelName ?? alias) in Settings, or rebuild the index with another model."
        )
      }
      return false
    }
    return true
  }

  /// Stops the search still in flight, so a burst of typing does not queue up
  /// searches nobody will see.
  private func cancelSearchInFlight() {
    searchTask?.cancel()
    searchTask = nil
  }

  enum Query {
    case text(String)
    case image(path: String, name: String, refinement: SearchRefinement)

    var kind: SearchResults.Kind {
      switch self {
      case .text: return .text
      case .image: return .image
      }
    }

    var title: String {
      switch self {
      case .text(let text): return "“\(text)”"
      case .image(_, let name, let refinement):
        return refinement.isEmpty ? "Similar to \(name)" : "Similar to \(name) \(refinement.summary)"
      }
    }
  }

  /// `interactive` is false for search-as-you-type, which reports problems in
  /// the status line instead of interrupting with an alert on every keystroke.
  private func runSearch(_ query: Query, in folder: URL, interactive: Bool = true) {
    searchGeneration += 1
    let generation = searchGeneration
    cancelSearchInFlight()
    pendingSearch = query.kind
    if case .image(_, _, let refinement) = query { shownRefinement = refinement }
    isSearching = true
    let engine = engine
    let progress: ProgressHandler = { [weak self] progress in
      Task { @MainActor in
        guard let self, generation == self.searchGeneration else { return }
        self.status = progress.message + "…"
      }
    }
    searchTask = Task {
      defer {
        if generation == searchGeneration {
          isSearching = false
          pendingSearch = nil
          searchTask = nil
        }
      }
      do {
        let response: SearchResponse
        switch query {
        case .text(let text):
          response = try await engine.search(
            folder: folder, text: text, limit: Studio.resultLimit, onProgress: progress)
        case .image(let path, _, let refinement) where refinement.isEmpty:
          response = try await engine.search(
            folder: folder, similarTo: path, limit: Studio.resultLimit, onProgress: progress)
        case .image(let path, _, let refinement):
          response = try await engine.search(
            folder: folder, similarTo: path, adding: refinement.adding,
            removing: refinement.removing, limit: Studio.resultLimit, onProgress: progress)
        }
        guard generation == searchGeneration else { return }  // a newer search superseded this one
        results = SearchResults(
          kind: query.kind, title: query.title, photos: response.images.map(Photo.init))
        // Search ranks the whole folder, so say "closest", not "matching".
        status =
          response.images.isEmpty
          ? "No matches" : "Showing the \(Format.count(response.total)) closest, best first"
      } catch EngineError.cancelled {
        return
      } catch is CancellationError {
        return
      } catch {
        guard generation == searchGeneration else { return }
        status = "Search did not finish"
        if interactive {
          alert = AlertMessage(title: "Search did not finish", message: error.localizedDescription)
        }
      }
    }
  }

  // MARK: - Duplicates

  func findDuplicates() {
    guard let folder, activity == nil else { return }
    guard hasIndex else {
      needsIndexPrompt = true
      return
    }
    let mode = duplicateMode
    let engine = engine
    Task {
      let found = await perform(.findingDuplicates) { progress in
        try await engine.duplicates(
          folder: folder, threshold: mode.threshold, exactOnly: mode == .exact,
          onProgress: progress)
      }
      guard let response = found else { return }
      let report = DuplicateReport(response)
      duplicates = report
      status =
        report.sets.isEmpty
        ? "No duplicates found" : "\(Format.count(report.extras.count)) extra copies found"
    }
  }

  func keep(_ photo: Photo, in set: DuplicateSet) {
    duplicates = duplicates?.keeping(photo.path, in: set.id)
  }

  /// Moves photos to the Trash and drops them from everything on screen.
  func moveToTrash(_ photos: [Photo]) {
    // One batch at a time: a double-click must not try to trash the same files twice.
    guard !photos.isEmpty, !isTrashing else { return }
    isTrashing = true
    let paths = photos.map(\.path)
    Task {
      let outcome = await Task.detached { FileTrash.move(paths) }.value
      isTrashing = false
      let gone = outcome.trashed
      library = library.filter { !gone.contains($0.path) }
      results = results?.removing(gone)
      duplicates = duplicates?.removing(gone)
      curation = curation?.removing(gone)
      junkSelection.subtract(gone)
      if let reference, gone.contains(reference.path) { self.reference = nil }
      preview = nil
      status = "Moved \(Format.images(gone.count)) to the Trash"
      if !outcome.failed.isEmpty {
        alert = AlertMessage(
          title: "Some files could not be moved to the Trash",
          message: outcome.failed.prefix(5).map { URL(fileURLWithPath: $0).lastPathComponent }
            .joined(separator: "\n"))
      }
      refreshIndexStatus()
    }
  }
}
