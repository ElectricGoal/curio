import Foundation

extension NativeEngine {
  static let maximumResults = 500

  public func search(
    folder: URL, text: String, limit: Int, onProgress: @escaping ProgressHandler
  ) async throws -> SearchResponse {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { throw EngineError.failed("Type something to search for.") }
    return try await search(folder: folder, limit: limit, onProgress: onProgress) { model in
      try await model.embed(text: query)
    }
  }

  public func search(
    folder: URL, similarTo imagePath: String, limit: Int, onProgress: @escaping ProgressHandler
  ) async throws -> SearchResponse {
    let url = URL(fileURLWithPath: imagePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw EngineError.failed("The reference image could not be found: \(url.lastPathComponent)")
    }
    return try await search(folder: folder, limit: limit, onProgress: onProgress) { model in
      let side = model.manifest.imageSize
      let prepared = try await Task.detached { try ImagePreprocessor.prepare(url, side: side) }.value
      return try await model.embed(image: prepared.tensor)
    }
  }

  private func search(
    folder: URL, limit: Int, onProgress: @escaping ProgressHandler,
    query: (any EmbeddingModel) async throws -> [Float]
  ) async throws -> SearchResponse {
    // Taken before anything is awaited: the query is embedded with the model
    // these vectors came from, even if the index is rebuilt in the meantime.
    let snapshot = try snapshot(for: folder)
    let alias = snapshot.modelAlias
    let model = try await model(alias) { onProgress(EngineProgress(message: "Loading model")) }
    try Self.checkCancelled()
    onProgress(EngineProgress(message: "Understanding your query"))
    let vector = try await query(model)
    try Self.checkCancelled()
    onProgress(EngineProgress(message: "Finding matching images"))
    let scores = VectorMath.scores(
      matrix: snapshot.matrix, rows: snapshot.paths.count, dimension: snapshot.dimension,
      query: vector)
    let best = VectorMath.top(scores, limit: max(1, min(limit, Self.maximumResults)))
    let images = best.compactMap {
      record(for: folder, snapshot.paths[$0], similarity: Double(scores[$0]))
    }
    return SearchResponse(images: images, total: images.count, model: alias)
  }

  public func duplicates(
    folder: URL, threshold: Double, exactOnly: Bool, onProgress: @escaping ProgressHandler
  ) async throws -> DuplicatesResponse {
    let limit = Float(max(0.5, min(1, threshold)))
    onProgress(EngineProgress("Comparing images", estimate: .start))
    let store = try openForReading(folder)
    let identical = try store.identicalFileGroups()
    store.close()
    var near: [(paths: [String], similarity: Double)] = []
    if !exactOnly {
      let snapshot = try snapshot(for: folder)
      let estimator = Locked(RateProgressEstimator())
      // The tail of the bar is for choosing keepers and reading file sizes.
      // Off the actor, so status checks and searches are not held up; a
      // detached task does not see this one's cancellation, so it is passed on.
      let comparing = Task.detached {
        try DuplicateFinder.nearGroups(
          in: snapshot, threshold: limit, isCancelled: { Task.isCancelled }
        ) { rows, total in
          let estimate = estimator.update {
            $0.at(done: Double(rows), of: Double(total), finishing: 0.1)
          }
          onProgress(EngineProgress("Comparing images", estimate: estimate))
        }
      }
      near = try await withTaskCancellationHandler {
        try await comparing.value
      } onCancel: {
        comparing.cancel()
      }
    }
    try Self.checkCancelled()
    onProgress(
      EngineProgress(
        "Grouping duplicates", estimate: ProgressEstimate(fraction: 0.9, eta: nil, ceiling: 0.99)))

    // Files moved or deleted since indexing must not appear as duplicates.
    var sizes: [String: Int64] = [:]
    func exists(_ path: String) -> Bool {
      if sizes[path] != nil { return true }
      guard let record = record(for: folder, path) else { return false }
      sizes[path] = record.size
      return true
    }
    let presentIdentical = identical.map { $0.filter(exists) }.filter { $0.count > 1 }
    let presentNear = near.map { (paths: $0.paths.filter(exists), similarity: $0.similarity) }
      .filter { $0.paths.count > 1 }
    let groups = DuplicateFinder.groups(identical: presentIdentical, near: presentNear) {
      sizes[$0] ?? 0
    }
    .map { group -> DuplicateGroup in
      let members = [(group.keeper, true)] + group.duplicates.map { ($0, false) }
      return DuplicateGroup(
        kind: group.isExact ? "exact" : "similar", similarity: group.similarity,
        files: members.compactMap { record(for: folder, $0.0, keep: $0.1) })
    }
    .filter { $0.files.count > 1 }
    let extras = groups.flatMap { $0.files.filter { $0.keep == false } }
    return DuplicatesResponse(
      groups: groups, redundant: extras.count, reclaimable: extras.reduce(0) { $0 + $1.size },
      threshold: Double(limit))
  }

  static func checkCancelled() throws {
    if Task.isCancelled { throw EngineError.cancelled }
  }
}
