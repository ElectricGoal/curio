import Foundation

/// One image as stored in a folder's index.
public struct IndexedImage: Equatable, Sendable {
  public let relativePath: String
  public let sha1: String
  public let modified: Double
  public let size: Int64
  public let width: Int
  public let height: Int
  public let vector: [Float]

  public init(
    relativePath: String, sha1: String, modified: Double, size: Int64, width: Int, height: Int,
    vector: [Float]
  ) {
    self.relativePath = relativePath
    self.sha1 = sha1
    self.modified = modified
    self.size = size
    self.width = width
    self.height = height
    self.vector = vector
  }
}

/// Every vector in an index, loaded for searching.
public struct IndexSnapshot: Sendable {
  /// The model whose vectors these are; a query must be embedded with the same one.
  public let modelAlias: String
  public let paths: [String]
  /// `paths.count × dimension` values, one row per path.
  public let matrix: [Float]
  public let dimension: Int
}

/// A folder's search index: one SQLite file in the hidden `.imgsearch` folder.
///
/// An image's metadata and its vector live in the same row, so they are saved
/// together or not at all. That makes an interrupted index run (pause, quit,
/// crash) safe by construction: whatever was committed is complete.
public final class IndexStore {
  public static let directoryName = ".imgsearch"
  public static let fileName = "index.sqlite"
  static let rebuildFileName = "index.rebuild.sqlite"
  static let manifestName = "manifest.json"
  /// Bumped when the layout changes. Version 1 was the Python app's format
  /// (a FAISS file plus a separate metadata database).
  public static let formatVersion = 2
  /// Files the version-1 format left behind, removed once it is replaced.
  static let legacyFiles = ["index.faiss", "meta.db", "meta.db-wal", "meta.db-shm", "skipped.json"]

  private static let schema = """
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS images (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      rel_path TEXT UNIQUE NOT NULL,
      sha1 TEXT NOT NULL,
      mtime REAL NOT NULL,
      size INTEGER NOT NULL,
      width INTEGER NOT NULL,
      height INTEGER NOT NULL,
      indexed_at REAL NOT NULL,
      vector BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS images_sha1 ON images(sha1);
    CREATE TABLE IF NOT EXISTS skipped (rel_path TEXT PRIMARY KEY, mtime REAL NOT NULL);
    """

  public let url: URL
  public let modelAlias: String
  public let modelName: String
  public let dimension: Int
  private let database: SQLiteDatabase

  public static func directory(in folder: URL) -> URL {
    folder.appendingPathComponent(directoryName)
  }

  public static func location(in folder: URL) -> URL {
    directory(in: folder).appendingPathComponent(fileName)
  }

  public static func exists(in folder: URL) -> Bool {
    FileManager.default.fileExists(atPath: location(in: folder).path)
  }

  /// Opens the index at `url`, creating an empty one for `model` if needed.
  /// Pass no model to open an existing index only.
  public init(url: URL, creatingFor model: ModelManifest? = nil) throws {
    let manager = FileManager.default
    guard model != nil || manager.fileExists(atPath: url.path) else { throw Self.notIndexed }
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    self.url = url
    // A local, because closures below run before every property is set.
    let database = try SQLiteDatabase(path: url.path)
    self.database = database
    try database.execute(Self.schema)
    func header() throws -> [String: String] {
      Dictionary(
        uniqueKeysWithValues: try database.query("SELECT key, value FROM meta") {
          ($0.text(0), $0.text(1))
        })
    }
    var meta = try header()
    // "New" means no header yet, not no file: a run killed just after creating
    // the file leaves one without a header, and the next run completes it.
    if meta.isEmpty {
      guard let model else {
        database.close()
        throw Self.notIndexed
      }
      let now = String(Date().timeIntervalSince1970)
      try database.transaction {
        for (key, value) in [
          ("format", String(Self.formatVersion)), ("model_alias", model.alias),
          ("model_name", model.name), ("dim", String(model.dim)), ("created_at", now),
          ("updated_at", now),
        ] {
          try database.run(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        }
      }
      meta = try header()
    }
    guard meta["format"] == String(Self.formatVersion), let alias = meta["model_alias"],
      let dimension = meta["dim"].flatMap(Int.init)
    else {
      throw EngineError.failed("This folder's index was made by a different version of the app.")
    }
    modelAlias = alias
    modelName = meta["model_name"] ?? alias
    self.dimension = dimension
  }

  private static var notIndexed: EngineError {
    .failed("This folder has not been indexed yet. Index it to enable search.")
  }

  public func close() {
    database.close()
  }

  /// Folds everything into the one database file and closes it, so the index
  /// can be moved or swapped as a single file.
  public func sealForMoving() throws {
    let blocked = try database.query("PRAGMA wal_checkpoint(TRUNCATE)") { $0.integer(0) }.first
    guard blocked == 0 else {
      throw EngineError.failed("The index is in use elsewhere and could not be finished.")
    }
    try database.execute("PRAGMA journal_mode=DELETE")
    database.close()
    // Empty by now; the system's SQLite can leave them behind all the same.
    for suffix in ["-wal", "-shm"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }

  // MARK: - Reading

  public func count() throws -> Int {
    Int(try database.query("SELECT COUNT(*) FROM images") { $0.integer(0) }.first ?? 0)
  }

  public var updatedAt: Double? {
    (try? database.query("SELECT value FROM meta WHERE key = 'updated_at'") { $0.text(0) })?
      .first.flatMap(Double.init)
  }

  /// What is indexed, for deciding what an update has to do.
  public func knownFiles() throws -> [String: (modified: Double, sha1: String)] {
    Dictionary(
      uniqueKeysWithValues: try database.query("SELECT rel_path, mtime, sha1 FROM images") {
        ($0.text(0), (modified: $0.real(1), sha1: $0.text(2)))
      })
  }

  /// Files that could not be decoded last time, with the modification time
  /// they had — so they are not retried until they change.
  public func skipped() throws -> [String: Double] {
    Dictionary(
      uniqueKeysWithValues: try database.query("SELECT rel_path, mtime FROM skipped") {
        ($0.text(0), $0.real(1))
      })
  }

  public func snapshot() throws -> IndexSnapshot {
    var paths: [String] = []
    var matrix: [Float] = []
    let expected = dimension * MemoryLayout<Float>.size
    let intact = try database.query("SELECT rel_path, vector FROM images ORDER BY id") {
      row -> Bool in
      let blob = row.blob(1)
      guard blob.count == expected else { return false }
      paths.append(row.text(0))
      blob.withUnsafeBytes { matrix.append(contentsOf: $0.bindMemory(to: Float.self)) }
      return true
    }
    // Searching around a bad row would quietly hide images; say so instead.
    guard intact.allSatisfy({ $0 }) else {
      throw EngineError.failed("This folder's index is damaged. Rebuild it to search.")
    }
    return IndexSnapshot(
      modelAlias: modelAlias, paths: paths, matrix: matrix, dimension: dimension)
  }

  /// Groups of paths whose files are byte-for-byte identical.
  public func identicalFileGroups() throws -> [[String]] {
    let rows = try database.query(
      """
      SELECT sha1, rel_path FROM images
      WHERE sha1 IN (SELECT sha1 FROM images GROUP BY sha1 HAVING COUNT(*) > 1)
      ORDER BY sha1, rel_path
      """
    ) { ($0.text(0), $0.text(1)) }
    return Dictionary(grouping: rows, by: \.0).values.map { $0.map(\.1) }
      .sorted { $0[0] < $1[0] }
  }

  // MARK: - Writing

  /// Adds or replaces images. The whole batch is saved, or none of it.
  public func save(_ images: [IndexedImage]) throws {
    guard !images.isEmpty else { return }
    let now = Date().timeIntervalSince1970
    try database.transaction {
      for image in images {
        guard image.vector.count == dimension else {
          throw EngineError.failed("An image was embedded with a different model than this index.")
        }
        let vector = image.vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try database.run(
          """
          INSERT INTO images (rel_path, sha1, mtime, size, width, height, indexed_at, vector)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(rel_path) DO UPDATE SET sha1 = excluded.sha1, mtime = excluded.mtime,
            size = excluded.size, width = excluded.width, height = excluded.height,
            indexed_at = excluded.indexed_at, vector = excluded.vector
          """,
          [
            .text(image.relativePath), .text(image.sha1), .real(image.modified),
            .integer(image.size), .integer(Int64(image.width)), .integer(Int64(image.height)),
            .real(now), .blob(vector),
          ])
        try database.run("DELETE FROM skipped WHERE rel_path = ?", [.text(image.relativePath)])
      }
      try touchUpdatedAt(now)
    }
  }

  /// Records that a file changed on disk but its contents did not.
  public func setModified(_ modified: Double, for path: String) throws {
    try database.run(
      "UPDATE images SET mtime = ? WHERE rel_path = ?", [.real(modified), .text(path)])
  }

  public func remove(_ paths: [String]) throws {
    guard !paths.isEmpty else { return }
    try database.transaction {
      for path in paths {
        try database.run("DELETE FROM images WHERE rel_path = ?", [.text(path)])
        try database.run("DELETE FROM skipped WHERE rel_path = ?", [.text(path)])
      }
      try touchUpdatedAt(Date().timeIntervalSince1970)
    }
  }

  public func markSkipped(_ path: String, modified: Double) throws {
    try database.run(
      "INSERT OR REPLACE INTO skipped (rel_path, mtime) VALUES (?, ?)",
      [.text(path), .real(modified)])
  }

  private func touchUpdatedAt(_ time: Double) throws {
    try database.run(
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('updated_at', ?)", [.text(String(time))])
  }

  // MARK: - Files around the database

  /// A small readable summary next to the database. Its version number also
  /// tells the older Python tool that this index is not in its format.
  public func writeManifest() throws {
    let manifest: [String: Any] = [
      "version": Self.formatVersion, "model_alias": modelAlias, "model_name": modelName,
      "dim": dimension, "count": try count(), "updated_at": updatedAt ?? 0,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(
      to: url.deletingLastPathComponent().appendingPathComponent(Self.manifestName),
      options: .atomic)
  }

  /// The model named by a version-1 index in this folder, if one is there.
  public static func legacyModel(in folder: URL) -> String? {
    let directory = directory(in: folder)
    guard !exists(in: folder),
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.faiss").path),
      let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return manifest["model_alias"] as? String ?? "unknown"
  }

  /// Removes a database file together with SQLite's side files.
  static func removeDatabase(at url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }
}
