import Foundation

/// The answers a decision model has already given about a folder's images.
///
/// An answer costs a fraction of a second of GPU time, so each is worked out
/// once and kept next to the folder's search index (in its own file, so
/// rebuilding the index does not throw them away). An answer belongs to the
/// image as it was: when the file changes, it is asked again.
final class DecisionStore {
  struct Answer: Equatable {
    /// The image's modification time when it was asked.
    let modified: Double
    /// How likely "yes" is; nil when the image could not be read.
    let probability: Double?
  }

  private let database: SQLiteDatabase

  static func location(in folder: URL) -> URL {
    IndexStore.directory(in: folder).appendingPathComponent("decisions.sqlite")
  }

  init(folder: URL) throws {
    let url = Self.location(in: folder)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      database = try SQLiteDatabase(path: url.path)
    } catch {
      throw EngineError.failed(
        "The answers for this folder could not be opened. Check that the folder can be written to.")
    }
    try database.execute(
      """
      CREATE TABLE IF NOT EXISTS answers (
        rel_path TEXT NOT NULL, question TEXT NOT NULL, model TEXT NOT NULL,
        mtime REAL NOT NULL, probability REAL,
        PRIMARY KEY (rel_path, question, model));
      """)
  }

  func close() { database.close() }

  /// Every answer `model` has given to `question`, by the image's path inside the folder.
  func answers(model: String, question: String) throws -> [String: Answer] {
    Dictionary(
      try database.query(
        "SELECT rel_path, mtime, probability FROM answers WHERE model = ? AND question = ?",
        [.text(model), .text(question)]
      ) { ($0.text(0), Answer(modified: $0.real(1), probability: $0.isNull(2) ? nil : $0.real(2))) },
      uniquingKeysWith: { _, latest in latest })
  }

  /// Records one image's answers; `probabilities` are nil when it could not be read.
  func save(model: String, path: String, modified: Double, questions: [String], probabilities: [Double]?)
    throws
  {
    try database.transaction {
      for (index, question) in questions.enumerated() {
        try database.run(
          "INSERT OR REPLACE INTO answers (rel_path, question, model, mtime, probability) VALUES (?, ?, ?, ?, ?)",
          [
            .text(path), .text(question), .text(model), .real(modified),
            probabilities.map { .real($0[index]) } ?? .null,
          ])
      }
    }
  }
}
