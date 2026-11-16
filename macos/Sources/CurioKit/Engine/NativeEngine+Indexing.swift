import Foundation

extension NativeEngine {
  public func index(
    folder: URL, model alias: String, rebuild: Bool, expected: Int?,
    onProgress: @escaping ProgressHandler
  ) async throws -> IndexResponse {
    guard !isIndexing else {
      throw EngineError.busy("Another folder is being indexed. Let it finish or pause it first.")
    }
    isIndexing = true
    defer {
      isIndexing = false
      indexingModel = nil
    }
    let started = Date()
    let directory = IndexStore.directory(in: folder)
    let liveURL = IndexStore.location(in: folder)
    let rebuildURL = directory.appendingPathComponent(IndexStore.rebuildFileName)
    // Left behind only if a previous rebuild was killed part-way.
    IndexStore.removeDatabase(at: rebuildURL)
    // A folder with no usable index is built from scratch either way.
    let replacing = rebuild && IndexStore.exists(in: folder)

    // An update continues with the index's own model; a rebuild adopts the request.
    var indexAlias = alias
    if !rebuild, IndexStore.exists(in: folder) {
      let existing = try IndexStore(url: liveURL)
      indexAlias = existing.modelAlias
      existing.close()
      guard ModelCatalog.entry(indexAlias) != nil else {
        throw EngineError.failed(
          "This folder was indexed with a model that is no longer available. Rebuild its index to continue."
        )
      }
    }

    // Claimed before the first await, so nothing swaps the model out from under this run.
    indexingModel = indexAlias

    var estimator = IndexProgressEstimator(
      timing: timings.timing(for: indexAlias), modelLoaded: loaded?.alias == indexAlias,
      expected: expected)
    onProgress(EngineProgress("Scanning images", estimate: estimator.scanning()))
    let files = await Task.detached { LibraryScanner.files(in: folder) }.value

    // Loading first also tells us the model's shape for a brand-new index.
    var announcedLoad = false
    let total = files.count
    let model = try await model(indexAlias) {
      announcedLoad = true
      onProgress(EngineProgress("Loading model", estimate: estimator.loading(total: total)))
    }
    _ = announcedLoad

    let store = try IndexStore(url: replacing ? rebuildURL : liveURL, creatingFor: model.manifest)
    var finished = false
    defer {
      store.close()
      if replacing, !finished { IndexStore.removeDatabase(at: rebuildURL) }
    }

    let known = try store.knownFiles()
    let skipped = try store.skipped()
    let present = Set(files.map(\.relativePath))
    let gone = known.keys.filter { !present.contains($0) }
    try store.remove(gone)
    // New or changed files — but not ones that failed to decode and have not changed since.
    let work = files.filter {
      known[$0.relativePath]?.modified != $0.modified && skipped[$0.relativePath] != $0.modified
    }

    var processed = 0
    var added = 0
    var unreadable = 0
    var cancelled = false
    estimator.embeddingStarted()
    if !work.isEmpty {
      onProgress(
        EngineProgress(
          "Indexing images", estimate: estimator.embedding(processed: 0, total: work.count),
          current: 0, total: work.count, unit: .images))
    }
    let side = model.manifest.imageSize
    for batchStart in stride(from: 0, to: work.count, by: Self.batchSize) {
      let batch = Array(work[batchStart..<min(batchStart + Self.batchSize, work.count)])
      let prepared = await Self.prepare(batch, side: side)
      var images: [IndexedImage] = []
      for (file, result) in zip(batch, prepared) {
        let image: PreparedImage
        switch result {
        case .success(let prepared): image = prepared
        case .failure(let failure) where failure.isPermanent:
          // Not a picture, or not ours to open: remembered, so it is not retried until it changes.
          unreadable += 1
          try store.markSkipped(file.relativePath, modified: file.modified)
          continue
        case .failure:
          // Could not be read this time. If the whole folder is gone (a drive
          // unplugged), stop rather than write every remaining file off.
          guard (try? folder.checkResourceIsReachable()) == true else {
            throw EngineError.failed(
              "The folder can no longer be reached. If it is on an external drive, reconnect it and index again."
            )
          }
          // Just this file: deleted or moved meanwhile. The next run sorts it out.
          continue
        }
        if known[file.relativePath]?.sha1 == image.sha1 {
          // Touched but not changed: the stored vector is still right.
          try store.setModified(file.modified, for: file.relativePath)
          continue
        }
        images.append(
          IndexedImage(
            relativePath: file.relativePath, sha1: image.sha1, modified: file.modified,
            size: file.size, width: image.width, height: image.height,
            vector: try await model.embed(image: image.tensor)))
      }
      try store.save(images)
      added += images.count
      processed += batch.count
      snapshots[folder.path] = nil
      onProgress(
        EngineProgress(
          "Indexing images",
          estimate: estimator.embedding(processed: processed, total: work.count),
          current: processed, total: work.count, unit: .images))
      if Task.isCancelled {
        // A rebuild is all-or-nothing; an update keeps what it finished.
        guard !replacing else { throw EngineError.cancelled }
        cancelled = true
        break
      }
    }
    if let rate = estimator.measuredRate { timings.record(indexAlias, imagesPerSecond: rate) }

    onProgress(EngineProgress("Saving search index", estimate: estimator.saving()))
    let count = try store.count()
    try store.writeManifest()
    if replacing {
      // The new index becomes one file, which then takes the old one's place
      // in a single step: at every instant the folder has a complete index.
      try store.sealForMoving()
      for suffix in ["-wal", "-shm"] {
        // Side files of the old index must never be read against the new one.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: liveURL.path + suffix))
      }
      guard rename(rebuildURL.path, liveURL.path) == 0 else {
        throw EngineError.failed(
          "The new index could not be put in place: \(String(cString: strerror(errno)))")
      }
    }
    finished = true
    for name in IndexStore.legacyFiles {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
    snapshots[folder.path] = nil
    return IndexResponse(
      count: count, added: added, skipped: unreadable, removed: gone.count,
      remaining: work.count - processed, cancelled: cancelled, model: indexAlias,
      modelName: model.manifest.name,
      seconds: (Date().timeIntervalSince(started) * 100).rounded() / 100)
  }

  typealias Prepared = Result<PreparedImage, ImagePreprocessor.Failure>

  /// Decodes a batch on background threads, in order, keeping why each failure happened.
  private static func prepare(_ batch: [ScannedFile], side: Int) async -> [Prepared] {
    await withTaskGroup(of: (Int, Prepared).self) { group in
      for (index, file) in batch.enumerated() {
        group.addTask {
          do {
            return (index, .success(try ImagePreprocessor.prepare(file.url, side: side)))
          } catch let failure as ImagePreprocessor.Failure {
            return (index, .failure(failure))
          } catch {
            return (index, .failure(.unreadable(file.url.lastPathComponent)))
          }
        }
      }
      var results = [Prepared](
        repeating: .failure(.unreadable("")), count: batch.count)
      for await (index, image) in group { results[index] = image }
      return results
    }
  }
}
