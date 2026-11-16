import XCTest

@testable import CurioKit

final class IndexStoreTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("curio-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  static func manifest(alias: String = "test-model", dim: Int = 3) -> ModelManifest {
    ModelManifest(
      format: 1, alias: alias, name: "Test Model", dim: dim, imageSize: 8, contextLength: 77,
      padToken: 0, startToken: 49406, endToken: 49407, precision: "float16", license: "MIT",
      imageModel: "image.mlpackage", textModel: "text.mlpackage", merges: "bpe_merges.txt")
  }

  private func image(_ path: String, sha1: String = "aa", vector: [Float] = [1, 0, 0]) -> IndexedImage {
    IndexedImage(
      relativePath: path, sha1: sha1, modified: 10, size: 100, width: 4, height: 3, vector: vector)
  }

  private func open(creating: Bool = true) throws -> IndexStore {
    try IndexStore(
      url: IndexStore.location(in: folder), creatingFor: creating ? Self.manifest() : nil)
  }

  func testOpeningAFolderWithNoIndexExplainsWhatToDo() {
    XCTAssertThrowsError(try open(creating: false)) { error in
      XCTAssertTrue(error.localizedDescription.contains("has not been indexed"))
    }
    XCTAssertFalse(IndexStore.exists(in: folder), "a failed open must not leave an empty index")
  }

  func testAnIndexInterruptedWhileBeingCreatedIsFinishedNextTime() throws {
    // What a crash between creating the file and writing its header leaves behind.
    let url = IndexStore.location(in: folder)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: url)

    XCTAssertThrowsError(try open(creating: false)) { error in
      XCTAssertTrue(error.localizedDescription.contains("has not been indexed"), "\(error)")
    }
    let store = try open()
    XCTAssertEqual([store.modelAlias, String(store.dimension)], ["test-model", "3"])
    try store.save([image("a.jpg")])
    XCTAssertEqual(try store.count(), 1)
  }

  func testSnapshotNamesTheModelItsVectorsCameFrom() throws {
    let store = try open()
    try store.save([image("a.jpg")])
    XCTAssertEqual(try store.snapshot().modelAlias, "test-model")
  }

  func testADamagedVectorIsReportedNotSilentlyLeftOut() throws {
    let store = try open()
    try store.save([image("a.jpg"), image("b.jpg", sha1: "bb")])
    store.close()
    let raw = try SQLiteDatabase(path: IndexStore.location(in: folder).path)
    try raw.run("UPDATE images SET vector = ? WHERE rel_path = 'b.jpg'", [.blob(Data([1, 2, 3]))])
    raw.close()

    XCTAssertThrowsError(try open(creating: false).snapshot()) { error in
      XCTAssertTrue(error.localizedDescription.contains("damaged"), "\(error)")
    }
  }

  func testAFinishedIndexIsOneFileSoItCanBeSwappedInWhole() throws {
    let store = try open()
    try store.save([image("a.jpg")])
    try store.sealForMoving()
    let files = try FileManager.default.contentsOfDirectory(atPath: IndexStore.directory(in: folder).path)
    XCTAssertEqual(files.filter { $0.hasPrefix("index.sqlite") }, ["index.sqlite"], "no side files left to move")
  }

  func testOpeningWhereNoFileCanBeCreatedFailsCleanly() {
    XCTAssertThrowsError(try SQLiteDatabase(path: "/nonexistent-\(UUID().uuidString)/index.sqlite")) { error in
      XCTAssertTrue(error.localizedDescription.contains("Could not open"), "\(error)")
    }
  }

  func testImagesAndVectorsSurviveReopening() throws {
    var store = try open()
    try store.save([image("a.jpg", vector: [1, 0, 0]), image("sub/b.png", vector: [0, 1, 0])])
    store.close()

    store = try open(creating: false)
    XCTAssertEqual(store.modelAlias, "test-model")
    XCTAssertEqual(store.dimension, 3)
    XCTAssertEqual(try store.count(), 2)
    let snapshot = try store.snapshot()
    XCTAssertEqual(snapshot.paths, ["a.jpg", "sub/b.png"])
    XCTAssertEqual(snapshot.matrix, [1, 0, 0, 0, 1, 0])
    XCTAssertEqual(try store.knownFiles()["a.jpg"]?.modified, 10)
  }

  func testSavingAnExistingPathReplacesIt() throws {
    let store = try open()
    try store.save([image("a.jpg", sha1: "old", vector: [1, 0, 0])])
    try store.save([image("a.jpg", sha1: "new", vector: [0, 0, 1])])

    XCTAssertEqual(try store.count(), 1)
    XCTAssertEqual(try store.knownFiles()["a.jpg"]?.sha1, "new")
    XCTAssertEqual(try store.snapshot().matrix, [0, 0, 1])
  }

  func testABatchIsSavedCompletelyOrNotAtAll() throws {
    let store = try open()
    let wrongSize = image("bad.jpg", vector: [1, 0])
    XCTAssertThrowsError(try store.save([image("good.jpg"), wrongSize]))
    XCTAssertEqual(try store.count(), 0, "the good image must not be saved without the rest")
  }

  func testRemovingAndTouching() throws {
    let store = try open()
    try store.save([image("a.jpg"), image("b.jpg")])
    try store.setModified(99, for: "a.jpg")
    try store.remove(["b.jpg"])

    XCTAssertEqual(try store.knownFiles().keys.sorted(), ["a.jpg"])
    XCTAssertEqual(try store.knownFiles()["a.jpg"]?.modified, 99)
  }

  func testUnreadableFilesAreRememberedUntilTheyAreIndexed() throws {
    let store = try open()
    try store.markSkipped("broken.jpg", modified: 5)
    XCTAssertEqual(try store.skipped(), ["broken.jpg": 5])

    try store.save([image("broken.jpg")])  // it was fixed and now decodes
    XCTAssertEqual(try store.skipped(), [:])
  }

  func testIdenticalFilesAreGroupedByContent() throws {
    let store = try open()
    try store.save([
      image("a.jpg", sha1: "same"), image("copy of a.jpg", sha1: "same"),
      image("c.jpg", sha1: "other"),
    ])
    XCTAssertEqual(try store.identicalFileGroups(), [["a.jpg", "copy of a.jpg"]])
  }

  func testManifestCarriesTheNewFormatVersion() throws {
    let store = try open()
    try store.save([image("a.jpg")])
    try store.writeManifest()

    let data = try Data(contentsOf: IndexStore.directory(in: folder).appendingPathComponent("manifest.json"))
    let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(manifest["version"] as? Int, 2)
    XCTAssertEqual(manifest["count"] as? Int, 1)
    XCTAssertEqual(manifest["model_alias"] as? String, "test-model")
  }

  func testAnIndexFromTheOldPythonAppIsRecognised() throws {
    let directory = IndexStore.directory(in: folder)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    XCTAssertNil(IndexStore.legacyModel(in: folder))

    try Data().write(to: directory.appendingPathComponent("index.faiss"))
    try Data(#"{"version":1,"model_alias":"mobileclip-s4"}"#.utf8)
      .write(to: directory.appendingPathComponent("manifest.json"))
    XCTAssertEqual(IndexStore.legacyModel(in: folder), "mobileclip-s4")

    _ = try open()  // once a new index exists, the old one no longer counts
    XCTAssertNil(IndexStore.legacyModel(in: folder))
  }
}
