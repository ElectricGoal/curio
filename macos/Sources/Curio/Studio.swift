import AppKit
import CurioKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
  case library, duplicates, cleanup, filter

  var id: String { rawValue }

  var title: String {
    switch self {
    case .library: return "Library"
    case .duplicates: return "Duplicates"
    case .cleanup: return "Clean Up"
    case .filter: return "Filter"
    }
  }
}

/// What the grid shows instead of the whole library.
struct SearchResults: Equatable {
  enum Kind { case text, image, tag, album }

  let kind: Kind
  let title: String
  let photos: [Photo]
  /// The tag or album shown, when the results are one.
  var label: CurationLabel? = nil

  /// Searches rank the whole folder; tags and albums are just their members.
  var isRanked: Bool { kind == .text || kind == .image }

  /// Image-to-image scores read naturally as "how alike"; text-to-image
  /// scores sit in a narrow low band that looks like a poor match even for
  /// the best result, so they are used for ranking only.
  var showsScores: Bool { kind == .image }

  func removing(_ paths: Set<String>) -> SearchResults {
    SearchResults(
      kind: kind, title: title, photos: photos.filter { !paths.contains($0.path) }, label: label)
  }
}

/// The image a search by example started from, which typed words then refine.
struct ReferenceImage: Equatable {
  let path: String
  let name: String
}

struct AlertMessage: Identifiable, Equatable {
  let id = UUID()
  let title: String
  let message: String
}

/// A dismissible summary of the last finished task.
struct Notice: Equatable {
  enum Style { case success, paused }

  let style: Style
  let title: String
  let message: String
  var offersResume: Bool { style == .paused }
}

/// The photo open in the full-window viewer, and the list it pages through.
struct PreviewState: Equatable {
  let photos: [Photo]
  let index: Int

  var photo: Photo { photos[index] }
  var hasPrevious: Bool { index > 0 }
  var hasNext: Bool { index < photos.count - 1 }

  func moved(by offset: Int) -> PreviewState {
    PreviewState(photos: photos, index: min(max(index + offset, 0), photos.count - 1))
  }
}

/// App state. Views read it; every change goes through its methods.
@MainActor
final class Studio: ObservableObject {
  static let resultLimit = 120
  static let idleStatus = "Your images, rediscovered."

  // Library
  @Published private(set) var folder: URL?
  @Published var library: [Photo] = []
  @Published private(set) var isScanning = false
  @Published private(set) var scanCount = 0
  @Published private(set) var recentFolders: [URL] = []
  @Published var sort: PhotoSort {
    didSet {
      guard sort != oldValue else { return }
      updatePreferences { $0.sort = sort }
      resortLibrary()
    }
  }
  @Published var thumbnailSize: Double

  // Search
  @Published var query = ""
  @Published var results: SearchResults?
  @Published var isSearching = false
  @Published var searchFocusRequests = 0
  @Published var reference: ReferenceImage?
  /// The refinement of the search by example on screen, so it is not run twice.
  var shownRefinement: SearchRefinement?

  // Index and engine
  @Published var indexStatus: IndexStatus?
  /// Why search cannot be used right now, in words for the user; nil when fine.
  @Published var engineProblem: String?
  @Published var activity: Activity?
  @Published var notice: Notice?
  @Published var models: [ModelInfo] = []
  @Published private(set) var selectedModel: String
  @Published var modelStorage: String?

  // Duplicates
  @Published var duplicates: DuplicateReport?
  @Published var duplicateMode: DuplicateMode = .nearIdentical

  // Tags, albums and Clean Up
  @Published var curation: Curation? { didSet { junkGroups = Studio.junkGroups(curation, in: library) } }
  /// Clutter groups found in the open folder, largest first. Kept, not computed:
  /// the sidebar reads it on every redraw.
  @Published private(set) var junkGroups: [(label: CurationLabel, photos: [Photo])] = []
  @Published var isCurating = false
  @Published var albums: [String]
  /// Clutter the user has marked for the Trash.
  @Published var junkSelection: Set<String> = []
  var curationGeneration = 0
  /// An album asked for before its members were known; opened once they are.
  var albumToOpen: String?

  // Filter
  @Published var filterSteps: [FilterStep]
  @Published var filterRun: FilterRun?
  @Published var isFiltering = false
  /// Why the chain could not run, in words for the user.
  @Published var filterProblem: String?
  /// The step whose output is previewed; nil for the final result.
  @Published var filterFocus: UUID?
  @Published var filterShowsRemoved = false
  /// The photos the preview shows, kept so the grid is not rebuilt on every redraw.
  @Published var filterPreview: [Photo] = []
  @Published var exportFolder: URL?
  @Published var exportMode: FileExport.Mode = .copy
  var filterGeneration = 0
  var filterTask: Task<Void, Never>?

  // Presentation
  @Published var page: Page = .library
  @Published var preview: PreviewState?
  @Published var alert: AlertMessage?
  @Published var needsIndexPrompt = false
  @Published var dismissedModelHint = false
  /// The first-launch model prompt was answered or put off, for this session.
  @Published var dismissedModelSetup = false
  @Published var status = Studio.idleStatus

  let engine: any SearchEngine
  /// Stops the task behind the visible activity, while there is one.
  var cancelCurrentActivity: (() -> Void)?
  private let store: PreferencesStore
  private var preferences: Preferences
  private var scanWorker: Task<[Photo]?, Never>?
  private var started = false
  /// Bumped whenever the open folder changes, so late replies can be ignored.
  private(set) var folderGeneration = 0
  var searchGeneration = 0
  /// The kind of search currently waiting on the engine, if any.
  var pendingSearch: SearchResults.Kind?
  /// The search in flight, so a newer one can cancel it.
  var searchTask: Task<Void, Never>?
  var liveSearch: Task<Void, Never>?
  /// True from the click on Index until the engine task is visible.
  @Published var isPreparingIndex = false
  var isTrashing = false

  /// The app as launched. Models, caches and settings live in the source
  /// checkout for a development build, or in Application Support for an
  /// installed copy (see `Installation`). `CURIO_PREFERENCES` moves the
  /// settings file and `CURIO_MODELS_URL` names a host for model downloads.
  convenience init() {
    let dataRoot = AppEnvironment.installation.dataRoot
    self.init(
      dataRoot: dataRoot,
      preferencesURL: AppEnvironment.environment["CURIO_PREFERENCES"]
        .map(URL.init(fileURLWithPath:)),
      engine: NativeEngine(
        dataRoot: dataRoot, bundledModels: AppEnvironment.bundledModels,
        remoteModels: AppEnvironment.remoteModels))
  }

  /// - Parameters:
  ///   - dataRoot: where settings are kept (and models, for the default engine).
  ///   - engine: the search backend; tests pass a stand-in.
  init(dataRoot: URL, preferencesURL: URL? = nil, engine: (any SearchEngine)? = nil) {
    self.engine = engine ?? NativeEngine(dataRoot: dataRoot)
    store = PreferencesStore(
      url: preferencesURL ?? dataRoot.appendingPathComponent(".runtime/preferences.json"))
    preferences = store.load()
    selectedModel = preferences.model
    sort = preferences.sort
    thumbnailSize = preferences.thumbnailSize
    recentFolders = Studio.existingFolders(preferences.recentFolders)
    albums = preferences.albums
    filterSteps = preferences.filterSteps
  }

  // MARK: - Derived state

  /// Photos currently on screen: search results, or the whole library.
  var visiblePhotos: [Photo] { results?.photos ?? library }

  var hasIndex: Bool {
    if let indexStatus { return indexStatus.indexed && indexStatus.count > 0 }
    // Until the engine has answered, go by whether an index is on disk.
    guard let folder else { return false }
    return IndexStore.exists(in: folder)
  }

  /// Whether a folder-bound task blocks indexing, searching and switching folders.
  var isFolderBusy: Bool { isPreparingIndex || (activity?.kind.usesFolder ?? false) }

  var selectedModelName: String {
    models.first { $0.alias == selectedModel }?.name ?? selectedModel
  }

  /// The index was built with a different (still available) model than the one selected.
  var indexUsesOtherModel: Bool {
    guard let indexStatus, indexStatus.indexed, !indexStatus.needsRebuild,
      let model = indexStatus.model
    else { return false }
    return model != selectedModel
  }

  /// No model is on this Mac yet, so search needs a download first.
  var needsModelSetup: Bool {
    !dismissedModelSetup && !models.isEmpty && !models.contains(where: \.installed)
      && models.contains(where: \.available)
  }

  /// The index was built with a model this app no longer includes.
  var indexNeedsRebuild: Bool { indexStatus?.needsRebuild ?? false }

  // MARK: - Launch

  /// Opens the folder passed on the command line, or the last one used.
  func start() {
    guard !started else { return }
    started = true
    refreshModels()  // tells whether a model must be downloaded first
    let argument = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
    if folder != nil {
      return  // a folder was already opened through Finder
    } else if let argument, Studio.isDirectory(URL(fileURLWithPath: argument)) {
      open(URL(fileURLWithPath: argument))
    } else if let path = preferences.folder, Studio.isDirectory(URL(fileURLWithPath: path)) {
      open(URL(fileURLWithPath: path))
    }
  }

  // MARK: - Folders

  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Open"
    panel.message = "Choose a folder of images to browse and search."
    if panel.runModal() == .OK, let url = panel.url { open(url) }
  }

  func open(_ url: URL) {
    let url = url.standardizedFileURL
    guard Studio.isDirectory(url) else {
      forget(url)
      alert = AlertMessage(
        title: "Folder not found",
        message: "“\(url.lastPathComponent)” has been moved or deleted, or its drive is not connected.")
      return
    }
    guard !isFolderBusy else {
      status = "Wait for the current task to finish, or cancel it, before switching folders."
      return
    }
    liveSearch?.cancel()
    searchGeneration += 1
    pendingSearch = nil
    folder = url
    updatePreferences { $0 = $0.opening(folder: url.path) }
    recentFolders = Studio.existingFolders(preferences.recentFolders)
    page = .library
    query = ""
    results = nil
    isSearching = false
    duplicates = nil
    reference = nil
    shownRefinement = nil
    curation = nil
    isCurating = false
    curationGeneration += 1
    junkSelection = []
    albumToOpen = nil
    filterRun = nil
    filterPreview = []
    filterProblem = nil
    isFiltering = false
    filterTask?.cancel()
    filterGeneration += 1
    indexStatus = nil
    engineProblem = nil
    notice = nil
    preview = nil
    dismissedModelHint = false
    reloadLibrary()
  }

  func forget(_ url: URL) {
    updatePreferences { $0 = $0.forgetting(folder: url.path) }
    recentFolders = Studio.existingFolders(preferences.recentFolders)
  }

  /// Re-reads the folder from disk and refreshes what is known about its index.
  func reloadLibrary() {
    guard let folder else { return }
    scanWorker?.cancel()
    folderGeneration += 1
    let generation = folderGeneration
    isScanning = true
    scanCount = 0
    status = "Reading your library…"
    let sort = sort
    let report: @Sendable (Int) -> Void = { [weak self] count in
      Task { @MainActor [weak self] in
        guard let self, self.folderGeneration == generation else { return }
        self.scanCount = count
      }
    }
    let worker = Task.detached(priority: .userInitiated) { () -> [Photo]? in
      LibraryScanner.scan(folder, onProgress: report).map(sort.sorted)
    }
    scanWorker = worker
    Task {
      guard let photos = await worker.value, generation == folderGeneration else { return }
      // The sort order may have changed while scanning.
      library = self.sort == sort ? photos : self.sort.sorted(photos)
      isScanning = false
      status = library.isEmpty ? "No images in this folder" : Format.images(library.count)
      refreshIndexStatus(preparingSearch: true)
    }
  }

  /// Sorting tens of thousands of names is slow enough to do off the main thread.
  private func resortLibrary() {
    let sort = sort
    let photos = library
    let generation = folderGeneration
    Task {
      let sorted = await Task.detached(priority: .userInitiated) { sort.sorted(photos) }.value
      // Skip if the folder or the order changed again while sorting.
      guard generation == folderGeneration, sort == self.sort, !isScanning else { return }
      library = sorted
    }
  }

  func revealFolder() {
    guard let folder else { return }
    NSWorkspace.shared.activateFileViewerSelecting([folder])
  }

  /// Folders drop in to open; images drop in to search by example.
  func handleDrop(_ urls: [URL]) -> Bool {
    let urls = urls.filter(\.isFileURL)  // a dragged web link is not a local image
    if let directory = urls.first(where: Studio.isDirectory) {
      open(directory)
      return true
    }
    if let image = urls.first(where: LibraryScanner.isImage), folder != nil {
      page = .library
      searchSimilar(toImageAt: image.path, named: image.lastPathComponent)
      return true
    }
    return false
  }

  // MARK: - Preferences

  func selectModel(_ alias: String) {
    guard alias != selectedModel else { return }
    selectedModel = alias
    dismissedModelHint = false
    updatePreferences { $0.model = alias }
  }

  /// Called when the size slider is released, so dragging does not hit the disk.
  func saveThumbnailSize() {
    updatePreferences { $0.thumbnailSize = thumbnailSize }
  }

  func updatePreferences(_ change: (inout Preferences) -> Void) {
    var updated = preferences
    change(&updated)
    guard updated != preferences else { return }
    preferences = updated
    do {
      try store.save(updated)
    } catch {
      status = "Could not save preferences: \(error.localizedDescription)"
    }
  }

  // MARK: - Viewer

  func showPreview(of photo: Photo, in photos: [Photo]) {
    guard let index = photos.firstIndex(where: { $0.path == photo.path }) else { return }
    // The viewer's arrow and space keys must not be typed into the search field.
    NSApp.keyWindow?.makeFirstResponder(nil)
    preview = PreviewState(photos: photos, index: index)
  }

  func focusSearch() {
    preview = nil
    page = .library
    searchFocusRequests += 1
  }

  // MARK: - Helpers

  static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private static func existingFolders(_ paths: [String]) -> [URL] {
    paths.map { URL(fileURLWithPath: $0) }.filter(isDirectory)
  }
}
