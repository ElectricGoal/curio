import Accelerate
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
    try await search(
      folder: folder, similarTo: imagePath, adding: [], removing: [], limit: limit,
      onProgress: onProgress)
  }

  public func search(
    folder: URL, similarTo imagePath: String, adding: [String], removing: [String], limit: Int,
    onProgress: @escaping ProgressHandler
  ) async throws -> SearchResponse {
    let url = URL(fileURLWithPath: imagePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw EngineError.failed("The reference image could not be found: \(url.lastPathComponent)")
    }
    return try await search(folder: folder, limit: limit, onProgress: onProgress) { model in
      let side = model.manifest.imageSize
      let prepared = try await Task.detached { try ImagePreprocessor.prepare(url, side: side) }.value
      var vector = try await model.embed(image: prepared.tensor)
      guard !adding.isEmpty || !removing.isEmpty else { return vector }
      // shortcut: each word moves the query by one unit vector; weight terms if results feel too pulled.
      for term in adding { vector = vDSP.add(vector, try await model.embed(text: term)) }
      for term in removing { vector = vDSP.subtract(vector, try await model.embed(text: term)) }
      return VectorMath.normalized(vector)
    }
  }

  public func scores(folder: URL, prompts: [String]) async throws -> PromptScores {
    let snapshot = try snapshot(for: folder)
    let model = try await model(snapshot.modelAlias)
    var vectors: [[Float]] = []
    for prompt in prompts {
      try Self.checkCancelled()
      vectors.append(try await promptVector(prompt, model: model))
    }
    let scores = await Task.detached {
      VectorMath.scores(
        matrix: snapshot.matrix, rows: snapshot.paths.count, dimension: snapshot.dimension,
        queries: vectors)
    }.value
    return PromptScores(
      paths: snapshot.paths.map { folder.appendingPathComponent($0).path }, prompts: prompts.count,
      scores: scores, model: snapshot.modelAlias)
  }

  /// A prompt's vector, embedded once per model.
  func promptVector(_ prompt: String, model: any EmbeddingModel) async throws -> [Float] {
    let key = model.manifest.alias + "\u{0}" + prompt
    if let known = promptVectors[key] { return known }
    let vector = try await model.embed(text: prompt)
    promptVectors[key] = vector
    return vector
  }

  /// How much better than worse each image looks, for the images given.
  /// Nil when the model cannot be used right now; duplicates then fall back to file size.
  private func shotQuality(_ snapshot: IndexSnapshot, paths: Set<String>) async -> [String: Float]? {
    guard !paths.isEmpty,
      let model = try? await model(snapshot.modelAlias),
      let good = try? await promptVector(Labels.goodShot, model: model),
      let bad = try? await promptVector(Labels.badShot, model: model)
    else { return nil }
    let direction = vDSP.subtract(good, bad)
    let d = snapshot.dimension
    var quality: [String: Float] = [:]
    for (row, path) in snapshot.paths.enumerated() where paths.contains(path) {
      quality[path] = VectorMath.dot(Array(snapshot.matrix[(row * d)..<((row + 1) * d)]), direction)
    }
    return quality
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
    var quality: [String: Float] = [:]
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
      try Self.checkCancelled()
      onProgress(
        EngineProgress(
          "Choosing the best shots", estimate: ProgressEstimate(fraction: 0.88, eta: nil, ceiling: 0.9)))
      quality = await shotQuality(snapshot, paths: Set(near.flatMap(\.paths))) ?? [:]
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
    let groups = DuplicateFinder.groups(
      identical: presentIdentical, near: presentNear, size: { sizes[$0] ?? 0 },
      quality: { quality[$0] })
    .map { group -> DuplicateGroup in
      let members = [(group.keeper, true)] + group.duplicates.map { ($0, false) }
      return DuplicateGroup(
        kind: group.isExact ? "exact" : "similar", similarity: group.similarity,
        files: members.compactMap { record(for: folder, $0.0, keep: $0.1) },
        bestShot: group.isBestShot ? folder.appendingPathComponent(group.keeper).path : nil)
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
