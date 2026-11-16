import Foundation
import XCTest

@testable import CurioKit

/// Decoder for JSON fixtures written with snake_case keys.
func snakeCaseDecoder() -> JSONDecoder {
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  return decoder
}

final class PreferencesTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testReadsFilesWrittenByTheFirstVersion() throws {
    let url = directory.appendingPathComponent("preferences.json")
    try Data(#"{"folder":"/Users/me/Pictures","model":"clip-vit-b32"}"#.utf8).write(to: url)

    let preferences = PreferencesStore(url: url).load()

    XCTAssertEqual(preferences.model, "clip-vit-b32")
    XCTAssertEqual(preferences.folder, "/Users/me/Pictures")
    XCTAssertEqual(preferences.recentFolders, [])
    XCTAssertEqual(preferences.sort, .name)
    XCTAssertEqual(Preferences().model, "mobileclip-s4", "matches the engine's default model")
  }

  func testEmptyFolderMeansNoFolderAndCorruptFilesFallBack() throws {
    let url = directory.appendingPathComponent("preferences.json")
    try Data(#"{"folder":"","model":"m","thumbnailSize":9000}"#.utf8).write(to: url)
    XCTAssertNil(PreferencesStore(url: url).load().folder)
    XCTAssertEqual(
      PreferencesStore(url: url).load().thumbnailSize, Preferences.thumbnailRange.upperBound)

    try Data("not json".utf8).write(to: url)
    XCTAssertEqual(PreferencesStore(url: url).load(), Preferences())
  }

  func testRoundTripsThroughDisk() throws {
    let store = PreferencesStore(url: directory.appendingPathComponent("nested/preferences.json"))
    let saved = Preferences(model: "m", thumbnailSize: 240, sort: .newest).opening(folder: "/a")
    try store.save(saved)
    XCTAssertEqual(store.load(), saved)
  }

  func testRecentsAreDeduplicatedNewestFirstAndCapped() {
    var preferences = Preferences()
    for index in 0..<12 { preferences = preferences.opening(folder: "/photos/\(index)") }
    preferences = preferences.opening(folder: "/photos/9")

    XCTAssertEqual(preferences.folder, "/photos/9")
    XCTAssertEqual(preferences.recentFolders.count, Preferences.recentLimit)
    XCTAssertEqual(Array(preferences.recentFolders.prefix(3)), ["/photos/9", "/photos/11", "/photos/10"])

    let forgotten = preferences.forgetting(folder: "/photos/9")
    XCTAssertNil(forgotten.folder)
    XCTAssertFalse(forgotten.recentFolders.contains("/photos/9"))
    XCTAssertEqual(preferences.folder, "/photos/9", "the original value is not mutated")
  }
}

final class PhotoTests: XCTestCase {
  private func photo(_ name: String, size: Int64, age: TimeInterval) -> Photo {
    Photo(
      path: "/p/" + name, name: name, size: size,
      modified: Date(timeIntervalSince1970: 1_000_000 - age))
  }

  func testSortOrders() {
    let photos = [
      photo("img10.jpg", size: 5, age: 30), photo("img2.jpg", size: 50, age: 10),
      photo("img1.jpg", size: 20, age: 20),
    ]
    XCTAssertEqual(PhotoSort.name.sorted(photos).map(\.name), ["img1.jpg", "img2.jpg", "img10.jpg"])
    XCTAssertEqual(PhotoSort.newest.sorted(photos).map(\.name), ["img2.jpg", "img1.jpg", "img10.jpg"])
    XCTAssertEqual(PhotoSort.oldest.sorted(photos).map(\.name), ["img10.jpg", "img1.jpg", "img2.jpg"])
    XCTAssertEqual(PhotoSort.largest.sorted(photos).map(\.name), ["img2.jpg", "img1.jpg", "img10.jpg"])
  }

  func testScannerFindsImagesAndSkipsHiddenAndOtherFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let nested = root.appendingPathComponent("trip")
    let hidden = root.appendingPathComponent(".curio")
    for directory in [nested, hidden] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    for file in ["a.JPG", "notes.txt", "trip/b.heic", ".curio/c.png", ".hidden.png"] {
      try Data("x".utf8).write(to: root.appendingPathComponent(file))
    }

    let photos = try XCTUnwrap(LibraryScanner.scan(root))

    XCTAssertEqual(Set(photos.map(\.name)), ["a.JPG", "b.heic"])
    XCTAssertEqual(photos.first?.size, 1)

    // The index's view of the same folder: relative keys, in a stable order.
    let files = LibraryScanner.files(in: root)
    XCTAssertEqual(files.map(\.relativePath), ["a.JPG", "trip/b.heic"])
    XCTAssertEqual(files[1].url.lastPathComponent, "b.heic")
    XCTAssertTrue(FileManager.default.fileExists(atPath: files[1].url.path))
    // Both views spell paths the same way, whatever symlinks lead to the folder.
    XCTAssertEqual(Set(photos.map(\.path)), Set(files.map(\.url.path)))
    XCTAssertTrue(photos.allSatisfy { $0.path.hasPrefix(root.path + "/") })
    XCTAssertGreaterThan(files[0].modified, 0)
  }

  func testRecordConversionKeepsScore() {
    let json = #"{"path":"/p/a.jpg","name":"a.jpg","size":12,"modified":100.5,"similarity":0.31}"#
    let record = try! JSONDecoder().decode(ImageRecord.self, from: Data(json.utf8))
    let photo = Photo(record)
    XCTAssertEqual(photo.score, 0.31)
    XCTAssertEqual(photo.modified, Date(timeIntervalSince1970: 100.5))
    XCTAssertEqual(photo.url.lastPathComponent, "a.jpg")
  }
}

final class FormattingTests: XCTestCase {
  func testRemainingTimeIsCoarse() {
    XCTAssertEqual(Format.remaining(2), "a few seconds left")
    XCTAssertEqual(Format.remaining(12), "about 15 sec left")
    XCTAssertEqual(Format.remaining(95), "about 2 min left")
    XCTAssertEqual(Format.remaining(3600), "about 1 hr left")
    XCTAssertEqual(Format.remaining(9000), "about 2.5 hr left")
  }

  func testCountsAndScores() {
    XCTAssertEqual(Format.images(1), "1 image")
    XCTAssertEqual(Format.images(0), "0 images")
    XCTAssertEqual(Format.score(0.286), "29%")
    XCTAssertEqual(Format.score(1.2), "100%")
  }

  func testStatusAndModelsDecodeFromEngineJSON() throws {
    let decoder = snakeCaseDecoder()
    let status = try decoder.decode(
      IndexStatus.self,
      from: Data(
        #"{"indexed":true,"total":10,"count":8,"pending":2,"missing":0,"unreadable":1,"model":"clip-vit-b32","model_name":"OpenAI CLIP","updated_at":12.5}"#
          .utf8))
    XCTAssertEqual(status.modelName, "OpenAI CLIP")
    XCTAssertEqual(status.updatedAt, 12.5)

    let models = try decoder.decode(
      ModelsResponse.self,
      from: Data(
        #"{"storage":"/m","models":[{"alias":"a","id":"org/a","name":"A","family":"clip","summary":"s","default":true,"installed":false,"available":true,"availability_message":"","size":0}]}"#
          .utf8))
    XCTAssertTrue(models.models[0].isDefault)

    let unindexed = try decoder.decode(
      IndexStatus.self,
      from: Data(
        #"{"indexed":false,"total":3,"count":0,"pending":3,"missing":0,"unreadable":0,"model":null,"model_name":null,"updated_at":null}"#
          .utf8))
    XCTAssertNil(unindexed.model)
    XCTAssertFalse(unindexed.needsRebuild)
    XCTAssertFalse(status.needsRebuild, "older engines omit model_available; assume it is fine")

    let retired = try decoder.decode(
      IndexStatus.self,
      from: Data(
        #"{"indexed":true,"total":3,"count":3,"pending":0,"missing":0,"unreadable":0,"model":"siglip-so400m","model_name":"SigLIP SO400M","model_available":false,"updated_at":1}"#
          .utf8))
    XCTAssertTrue(retired.needsRebuild)
  }
}

final class EngineDiagnosisTests: XCTestCase {
  func testPermissionFailuresPointToPrivacySettings() {
    let denied = NSError(
      domain: NSPOSIXErrorDomain, code: 1,
      userInfo: [NSLocalizedDescriptionKey: "The file couldn’t be opened. Operation not permitted"])
    XCTAssertEqual(EngineDiagnosis.message(for: denied), EngineDiagnosis.permissionHint)
    XCTAssertEqual(
      EngineDiagnosis.message(for: EngineError.failed("You don’t have permission to view it.")),
      EngineDiagnosis.permissionHint)
  }

  func testOtherFailuresKeepTheirOwnWords() {
    XCTAssertEqual(EngineDiagnosis.message(for: EngineError.failed("bad folder")), "bad folder")
    XCTAssertEqual(EngineDiagnosis.message(for: EngineError.busy("indexing")), "indexing")
  }
}
