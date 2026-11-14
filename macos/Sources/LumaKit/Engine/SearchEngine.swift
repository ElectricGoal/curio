import Foundation

/// Receives progress reports from a long engine call. May be called from any thread.
public typealias ProgressHandler = @Sendable (EngineProgress) -> Void

/// Everything the app asks of its search backend.
///
/// Long calls report progress through `onProgress` and stop when the calling
/// task is cancelled. An index update that is cancelled keeps what it has
/// done and says so in its result; anything else throws `EngineError.cancelled`.
public protocol SearchEngine: Sendable {
  /// How much of the folder is searchable, and how much work an update would be.
  func status(folder: URL) async throws -> IndexStatus
  /// Loads the folder's model ahead of the first search.
  func prepare(folder: URL) async throws
  /// Indexes new and changed images, or replaces the index when `rebuild` is set.
  /// `expected` is the caller's count of images to do, for an estimate up front.
  func index(
    folder: URL, model: String, rebuild: Bool, expected: Int?, onProgress: @escaping ProgressHandler
  ) async throws -> IndexResponse
  func search(folder: URL, text: String, limit: Int, onProgress: @escaping ProgressHandler) async throws
    -> SearchResponse
  func search(folder: URL, similarTo imagePath: String, limit: Int, onProgress: @escaping ProgressHandler)
    async throws -> SearchResponse
  func duplicates(
    folder: URL, threshold: Double, exactOnly: Bool, onProgress: @escaping ProgressHandler
  ) async throws -> DuplicatesResponse
  func models() async throws -> ModelsResponse
  func downloadModel(_ alias: String, onProgress: @escaping ProgressHandler) async throws -> ModelChange
  func deleteModel(_ alias: String) async throws -> ModelChange
}
