import CurioKit
import SwiftUI

/// Tags, smart savedSearches and Clean Up: one pass of the model over the index labels them all.
extension Studio {
  var curationLabels: [CurationLabel] { Labels.tags + Labels.junk + savedSearches.map(Labels.album) }

  static func junkGroups(_ curation: Curation?, in library: [Photo]) -> [(label: CurationLabel, photos: [Photo])] {
    guard let curation else { return [] }
    let byPath = Dictionary(library.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    return curation.used(Labels.junk)
      .map { ($0.label, curation.paths(for: $0.label).compactMap { byPath[$0] }) }
      .filter { !$0.1.isEmpty }
  }

  var junkCount: Int { junkGroups.reduce(0) { $0 + $1.photos.count } }

  /// Tags present in the open folder, most common first.
  var folderTags: [(label: CurationLabel, count: Int)] { curation?.used(Labels.tags) ?? [] }

  // MARK: - Labelling

  /// Labels the folder in the background. Search keeps working if it fails,
  /// so failures stay quiet: tags and savedSearches are extras.
  func refreshCuration() {
    guard let folder, hasIndex, !indexNeedsRebuild else { return }
    curationGeneration += 1
    let generation = curationGeneration
    let labels = curationLabels
    let engine = engine
    isCurating = true
    Task {
      defer { if generation == curationGeneration { isCurating = false } }
      guard let scores = try? await engine.scores(folder: folder, prompts: labels.map(\.prompt))
      else { return }
      let built = await Task.detached { Curation(scores: scores, labels: labels) }.value
      guard generation == curationGeneration else { return }  // a newer pass, or another folder
      // Files trashed meanwhile stay out.
      let present = Set(library.map(\.path))
      curation = built.removing(Set(scores.paths).subtracting(present))
      junkSelection.formIntersection(present)
      refreshShownLabel()
      if let name = albumToOpen {
        albumToOpen = nil
        showSavedSearch(name)
      }
    }
  }

  /// Re-labels when the index changed since the last pass.
  func refreshCurationIfStale() {
    guard let status = indexStatus, status.indexed, !status.needsRebuild, !isCurating,
      curation?.imageCount != status.count
    else { return }
    refreshCuration()
  }

  private func photos(for label: CurationLabel, in curation: Curation) -> [Photo] {
    let byPath = Dictionary(library.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    return curation.paths(for: label).compactMap { byPath[$0] }
  }

  // MARK: - Showing a tag or album

  /// Shows a tag's or album's photos in the library; showing it again goes back to all.
  func show(_ label: CurationLabel) {
    if results?.label == label, page == .library {
      clearSearch()
      return
    }
    // Without an index there is nothing to sort; say what is needed instead of waiting forever.
    guard folder != nil else {
      status = "Open a folder to see “\(label.name)”."
      return
    }
    guard hasIndex else {
      needsIndexPrompt = true
      return
    }
    guard let curation else {
      status = "Still sorting your images. This takes a moment the first time."
      if label.kind == .album { albumToOpen = label.name }
      return
    }
    clearSearch()
    page = .library
    let photos = photos(for: label, in: curation)
    results = SearchResults(
      kind: label.kind == .album ? .album : .tag, title: label.name, photos: photos, label: label)
    status = photos.isEmpty ? "No images match “\(label.name)” yet" : Format.images(photos.count)
  }

  func showSavedSearch(_ name: String) { show(Labels.album(name)) }

  /// Keeps a tag or album on screen up to date after re-labelling.
  private func refreshShownLabel() {
    guard let label = results?.label, let curation else { return }
    results = SearchResults(
      kind: results?.kind ?? .tag, title: label.name, photos: photos(for: label, in: curation),
      label: label)
  }

  // MARK: - Albums

  /// Adds an album matching `words` and opens it once its photos are known.
  func addSavedSearch(_ words: String) {
    let name = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    if let existing = savedSearches.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
      showSavedSearch(existing)
      return
    }
    savedSearches.append(name)
    updatePreferences { $0.albums = savedSearches }
    guard folder != nil, hasIndex else {
      status = "Saved “\(name)”. It fills in once a folder is indexed."
      return
    }
    albumToOpen = name
    status = "Gathering photos for “\(name)”…"
    refreshCuration()
  }

  /// Keeps the current text search as an album.
  func saveSearch() {
    guard results?.kind == .text else { return }
    addSavedSearch(query)
  }

  func removeSavedSearch(_ name: String) {
    savedSearches.removeAll { $0 == name }
    updatePreferences { $0.albums = savedSearches }
    if results?.label == Labels.album(name) { clearSearch() }
    status = "Removed the album “\(name)”. No photos were changed."
  }

  // MARK: - Clean Up

  func toggleJunk(_ photo: Photo) {
    if junkSelection.contains(photo.path) {
      junkSelection.remove(photo.path)
    } else {
      junkSelection.insert(photo.path)
    }
  }

  func setJunk(_ photos: [Photo], selected: Bool) {
    let paths = Set(photos.map(\.path))
    if selected { junkSelection.formUnion(paths) } else { junkSelection.subtract(paths) }
  }

  var selectedJunk: [Photo] { library.filter { junkSelection.contains($0.path) } }
}
