import Foundation
import SQLite3

/// A minimal wrapper over the system SQLite: enough for the index, no more.
final class SQLiteDatabase {
  struct Failure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// Tells SQLite to copy bound text and blobs, since Swift frees them after the call.
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private static let busyTimeoutMilliseconds: Int32 = 5000

  private var handle: OpaquePointer?

  init(path: String) throws {
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
      sqlite3_close(handle)
      handle = nil  // or deinit would close it a second time
      throw Failure(message: "Could not open the index: \(message)")
    }
    // Another process with the index open (a second copy of the app) is waited for, briefly.
    sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
    // Write-ahead logging keeps readers and a writer from blocking each other
    // and makes each transaction durable without rewriting the file.
    try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
  }

  deinit { sqlite3_close(handle) }

  func close() {
    sqlite3_close(handle)
    handle = nil
  }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
  }

  /// Runs `body` in one transaction: all of it is saved, or none of it.
  func transaction<Result>(_ body: () throws -> Result) throws -> Result {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  /// Runs a statement that returns no rows.
  func run(_ sql: String, _ values: [Value] = []) throws {
    let statement = try prepare(sql, values)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
  }

  /// Runs a query, handing each row to `read`.
  func query<Row>(_ sql: String, _ values: [Value] = [], _ read: (Cursor) -> Row) throws -> [Row] {
    let statement = try prepare(sql, values)
    defer { sqlite3_finalize(statement) }
    var rows: [Row] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: rows.append(read(Cursor(statement: statement)))
      case SQLITE_DONE: return rows
      default: throw failure()
      }
    }
  }

  enum Value {
    case text(String)
    case real(Double)
    case integer(Int64)
    case blob(Data)
    case null
  }

  struct Cursor {
    fileprivate let statement: OpaquePointer?

    func text(_ column: Int32) -> String {
      sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func blob(_ column: Int32) -> Data {
      guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
      return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
  }

  private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let status: Int32
      switch value {
      case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, Self.transient)
      case .real(let number): status = sqlite3_bind_double(statement, index, number)
      case .integer(let number): status = sqlite3_bind_int64(statement, index, number)
      case .null: status = sqlite3_bind_null(statement, index)
      case .blob(let data):
        status = data.withUnsafeBytes {
          sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient)
        }
      }
      guard status == SQLITE_OK else {
        sqlite3_finalize(statement)
        throw failure()
      }
    }
    return statement
  }

  private func failure() -> Failure {
    Failure(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "the index is closed")
  }
}
