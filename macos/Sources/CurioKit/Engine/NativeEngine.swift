import Foundation

/// The search backend, running inside the app: Core ML for the model, SQLite
/// for the index, Accelerate for the search. No helper process.
///
/// It is an actor, so requests never race on the model or an index. Long work
/// awaits between steps, which lets a quick request (a status check, a search)
/// run in the middle of an index.
public actor NativeEngine: SearchEngine {
  public typealias ModelLoader = @Sendable (_ alias: String) async throws -> any EmbeddingModel

  /// Images decoded and embedded per step. Small enough to stay responsive.
  static let batchSize = 8
  /// A model unused for this long is released to give its memory back.
  static let idleUnloadSeconds: Double = 600

  let library: ModelLibrary
  let timings: TimingStore
  let loadModel: ModelLoader
  /// Where Core ML's compiled form of each model is kept between launches.
  let compiledDirectory: URL
  var loaded: (alias: String, model: any EmbeddingModel)?
  var loading: (id: UUID, alias: String, task: Task<any EmbeddingModel, Error>)?
  /// Vectors of recently searched folders, keyed by folder path.
  var snapshots: [String: IndexSnapshot] = [:]
  /// Embedded label and quality prompts, keyed by model alias and prompt.
  var promptVectors: [String: [Float]] = [:]
  /// The model an index run is using right now. While it is set, requests
  /// that need a different model are told to wait instead of swapping it out.
  var indexingModel: String?
  var isIndexing = false
  var idleTimer: Task<Void, Never>?

  /// - Parameters:
  ///   - dataRoot: where models, caches and timings are kept.
  ///   - bundledModels: models shipped inside the app, if any.
  ///   - remoteModels: base address of hosted models, if any.
  ///   - modelLoader: replaces Core ML loading; used by tests.
  public init(
    dataRoot: URL, bundledModels: URL? = nil, remoteModels: URL? = nil,
    modelLoader: ModelLoader? = nil
  ) {
    let library = ModelLibrary(
      installDirectory: dataRoot.appendingPathComponent("models/coreml"),
      bundledDirectory: bundledModels, remote: remoteModels)
    self.library = library
    let compiledDirectory = dataRoot.appendingPathComponent(".cache/compiled")
    self.compiledDirectory = compiledDirectory
    timings = TimingStore(url: dataRoot.appendingPathComponent(".runtime/timings.json"))
    loadModel =
      modelLoader ?? { alias in
        guard let directory = library.directory(for: alias) else {
          let name = ModelCatalog.entry(alias)?.name ?? alias
          throw EngineError.failed("\(name) is not installed. Add it from the Models page.")
        }
        return try await CoreMLEmbeddingModel.load(
          directory: directory, cache: compiledDirectory.appendingPathComponent(alias))
      }
  }

  // MARK: - Model

  var isModelLoaded: Bool { loaded != nil }

  /// The model for `alias`, loading it if needed. `willLoad` runs only when a
  /// load is actually about to start.
  ///
  /// Other requests run while a load is awaited, so nothing read before an
  /// `await` here is assumed to still hold after it.
  func model(_ alias: String, willLoad: () -> Void = {}) async throws -> any EmbeddingModel {
    scheduleIdleUnload()
    // One load at a time: two models in memory at once is what an 8 GB Mac cannot afford.
    while let pending = loading {
      if pending.alias == alias { return try await pending.task.value }
      _ = await pending.task.result
      // Its owner clears it too, but may not have run yet; without this the wait would spin.
      if loading?.id == pending.id { loading = nil }
    }
    if let loaded, loaded.alias == alias { return loaded.model }
    try refuseIfIndexingUsesAnotherModel(than: alias)
    willLoad()
    let loader = loadModel
    let started = Date()
    let id = UUID()
    let task = Task { try await loader(alias) }
    loading = (id, alias, task)
    defer { if loading?.id == id { loading = nil } }
    let model = try await task.value
    guard model.manifest.alias == alias else {
      throw EngineError.failed(
        "The files installed for \(alias) belong to a different model (\(model.manifest.alias)).")
    }
    // An index run may have claimed the engine for another model during the load.
    try refuseIfIndexingUsesAnotherModel(than: alias)
    timings.record(alias, loadSeconds: Date().timeIntervalSince(started))
    loaded = (alias, model)
    return model
  }

  private func refuseIfIndexingUsesAnotherModel(than alias: String) throws {
    if let indexingModel, indexingModel != alias {
      throw EngineError.busy(
        "Indexing is using another model. Let it finish or pause it, then try again.")
    }
  }

  /// Whether `alias` is being loaded or used by an index run right now.
  private func isInUse(_ alias: String) -> Bool {
    indexingModel == alias || loading?.alias == alias
  }

  private func scheduleIdleUnload() {
    idleTimer?.cancel()
    idleTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.idleUnloadSeconds))
      guard !Task.isCancelled else { return }
      await self?.unloadIfIdle()
    }
  }

  private func unloadIfIdle() {
    guard !isIndexing, loading == nil else {
      // Still working: look again later, or the model would stay loaded for good.
      scheduleIdleUnload()
      return
    }
    loaded = nil
    snapshots = [:]
  }

  // MARK: - Models

  public func models() async throws -> ModelsResponse {
    ModelsResponse(models: library.models(), storage: library.installDirectory.path)
  }

  public func downloadModel(_ alias: String, onProgress: @escaping ProgressHandler) async throws
    -> ModelChange
  {
    let name = ModelCatalog.entry(alias)?.name ?? alias
    guard !isInUse(alias) else {
      throw EngineError.busy("\(name) is in use. Let indexing finish or pause it first.")
    }
    let message = "Downloading \(name)"
    onProgress(EngineProgress(message, estimate: .start))
    let estimator = Locked(RateProgressEstimator())
    try await library.install(alias) { done, total in
      // The last sliver of the bar is for verifying and installing the files.
      let estimate = estimator.update { $0.at(done: Double(done), of: Double(total), finishing: 0.01) }
      onProgress(
        EngineProgress(
          message, estimate: estimate, current: Int(done), total: Int(total), unit: .bytes))
    }
    forget(alias)
    onProgress(EngineProgress(message, estimate: .done))
    return ModelChange(model: alias, installed: true)
  }

  public func deleteModel(_ alias: String) async throws -> ModelChange {
    guard !isInUse(alias) else {
      let name = ModelCatalog.entry(alias)?.name ?? alias
      throw EngineError.busy("\(name) is in use. Let indexing finish or pause it first.")
    }
    try library.remove(alias)
    forget(alias)
    return ModelChange(model: alias, installed: library.directory(for: alias) != nil)
  }

  /// Drops what was derived from a model's files after they changed or went away.
  private func forget(_ alias: String) {
    if loaded?.alias == alias { loaded = nil }
    promptVectors = promptVectors.filter { !$0.key.hasPrefix(alias + "\u{0}") }
    try? FileManager.default.removeItem(at: compiledDirectory.appendingPathComponent(alias))
  }

  // MARK: - Status

  public func status(folder: URL) async throws -> IndexStatus {
    let files = await Task.detached { LibraryScanner.files(in: folder) }.value
    if let legacy = IndexStore.legacyModel(in: folder) {
      return IndexStatus(
        indexed: true, total: files.count, count: 0, pending: files.count, missing: 0,
        unreadable: 0, model: legacy, modelName: "an earlier version of this app",
        modelAvailable: false, updatedAt: nil,
        rebuildReason:
          "Its index was made by an earlier version of the app, in a format this version does not read."
      )
    }
    guard IndexStore.exists(in: folder) else {
      return IndexStatus(
        indexed: false, total: files.count, count: 0, pending: files.count, missing: 0,
        unreadable: 0, model: nil, modelName: nil, modelAvailable: nil, updatedAt: nil)
    }
    let store: IndexStore
    do {
      store = try IndexStore(url: IndexStore.location(in: folder))
    } catch {
      return IndexStatus(
        indexed: true, total: files.count, count: 0, pending: files.count, missing: 0,
        unreadable: 0, model: nil, modelName: "an unreadable index", modelAvailable: false,
        updatedAt: nil, rebuildReason: "Its index could not be read.")
    }
    defer { store.close() }
    let known = try store.knownFiles()
    let skipped = try store.skipped()
    let present = Set(files.map(\.relativePath))
    let unreadable = files.filter { skipped[$0.relativePath] == $0.modified }.count
    let stale = files.filter { known[$0.relativePath]?.modified != $0.modified }.count
    let available = ModelCatalog.entry(store.modelAlias) != nil
    return IndexStatus(
      indexed: true, total: files.count, count: known.count, pending: max(0, stale - unreadable),
      missing: known.keys.filter { !present.contains($0) }.count, unreadable: unreadable,
      model: store.modelAlias, modelName: store.modelName, modelAvailable: available,
      updatedAt: store.updatedAt,
      rebuildReason: available
        ? nil : "It was indexed with \(store.modelName), which this version no longer includes.")
  }

  public func prepare(folder: URL) async throws {
    let model = try await model(try snapshot(for: folder).modelAlias)
    // The first inference pays one-off GPU setup; spend it before the first query.
    _ = try await model.embed(text: "warm up")
  }

  // MARK: - Shared helpers

  /// The folder's vectors, from memory when they are still current.
  ///
  /// A snapshot is a value: vectors, paths and the model they came from, all
  /// from one moment. Work that awaits should take one first and keep using
  /// it, so an index rebuilt meanwhile cannot be mixed into the answer.
  func snapshot(for folder: URL) throws -> IndexSnapshot {
    if let cached = snapshots[folder.path] { return cached }
    let store = try openForReading(folder)
    defer { store.close() }
    let snapshot = try store.snapshot()
    snapshots[folder.path] = snapshot
    return snapshot
  }

  /// Opens the folder's index, explaining what to do when it cannot be used.
  func openForReading(_ folder: URL) throws -> IndexStore {
    if IndexStore.legacyModel(in: folder) != nil {
      throw EngineError.failed(
        "This folder's index was made by an earlier version of the app. Rebuild it to search.")
    }
    let store = try IndexStore(url: IndexStore.location(in: folder))
    guard ModelCatalog.entry(store.modelAlias) != nil else {
      store.close()
      throw EngineError.failed(
        "This folder was indexed with a model that is no longer available. Rebuild its index to search it."
      )
    }
    return store
  }

  func record(for folder: URL, _ relativePath: String, similarity: Double? = nil, keep: Bool? = nil)
    -> ImageRecord?
  {
    let url = folder.appendingPathComponent(relativePath)
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
      let size = values.fileSize
    else { return nil }  // moved or deleted since it was indexed
    return ImageRecord(
      path: url.path, name: url.lastPathComponent, size: Int64(size),
      modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
      similarity: similarity, keep: keep)
  }
}

/// A value shared with a `@Sendable` callback, guarded by a lock.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func update<Result>(_ change: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return change(&value)
  }
}
