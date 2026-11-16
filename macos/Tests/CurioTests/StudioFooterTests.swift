import CurioKit
import XCTest

@testable import Curio

/// The footer's few words about the folder, its index and the model.
@MainActor
final class StudioFooterTests: XCTestCase {
  private var folder: URL!
  private var engine: FakeEngine!

  override func setUp() async throws {
    folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("curio-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["a.jpg", "b.jpg"] { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
    engine = FakeEngine()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: folder)
  }

  private func studio() -> Studio {
    Studio(dataRoot: folder, preferencesURL: folder.appendingPathComponent(".prefs.json"), engine: engine)
  }

  private func wait(_ what: String, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
      guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func status(indexed: Bool, count: Int = 0, pending: Int = 0, reason: String? = nil) -> IndexStatus {
    IndexStatus(
      indexed: indexed, total: 2, count: count, pending: pending, missing: 0, unreadable: 0,
      model: indexed ? "clip-vit-b32" : nil, modelName: indexed ? "Index Model" : nil,
      modelAvailable: indexed ? reason == nil : nil, updatedAt: nil, rebuildReason: reason)
  }

  func testWithNoFolderThereIsOnlyTheModel() async {
    let studio = studio()
    await studio.loadModels()
    XCTAssertNil(studio.footerImages)
    XCTAssertNil(studio.footerIndex)
    XCTAssertEqual(studio.footerModel, "CLIP-VIT-B32", "the model new indexes will use")
  }

  func testAnIndexedFolderShowsItsImagesWhatIsSearchableAndItsOwnModel() async throws {
    engine.status = .success(status(indexed: true, count: 2))
    let studio = studio()
    studio.open(folder)
    try await wait("the folder and its index") { studio.library.count == 2 && studio.indexStatus != nil }

    XCTAssertEqual(studio.footerImages, "2 images")
    XCTAssertEqual(studio.footerIndex, "2 searchable")
    XCTAssertEqual(studio.footerModel, "Index Model", "the model this folder was indexed with")
  }

  func testNewImagesAreCountedBesideWhatIsSearchable() async throws {
    engine.status = .success(status(indexed: true, count: 1, pending: 1))
    let studio = studio()
    studio.open(folder)
    try await wait("the index") { studio.indexStatus != nil }
    XCTAssertEqual(studio.footerIndex, "1 searchable · 1 new")
  }

  func testAFolderWithoutAnIndexSaysSoAndNamesTheSelectedModel() async throws {
    engine.status = .success(status(indexed: false))
    let studio = studio()
    await studio.loadModels()
    studio.open(folder)
    XCTAssertEqual(studio.footerIndex, "Checking index…", "before the engine has answered")
    try await wait("the index") { studio.indexStatus != nil }
    XCTAssertEqual(studio.footerIndex, "Not indexed")
    XCTAssertEqual(studio.footerModel, "CLIP-VIT-B32")
  }

  func testAnIndexThatMustBeRebuiltAndASearchThatCannotRunAreNamed() async throws {
    engine.status = .success(status(indexed: true, count: 2, reason: "made by an older version"))
    let outdated = studio()
    await outdated.loadModels()
    outdated.open(folder)
    try await wait("the index") { outdated.indexStatus != nil }
    XCTAssertEqual(outdated.footerIndex, "Index out of date")
    XCTAssertEqual(outdated.footerModel, "CLIP-VIT-B32", "not the model of an index that cannot be used")

    engine.status = .failure(EngineError.failed("no answer"))
    let broken = studio()
    broken.open(folder)
    try await wait("the problem") { broken.engineProblem != nil }
    XCTAssertEqual(broken.footerIndex, "Search unavailable")
  }

  func testTheMessageIsLeftOutWhenItOnlyRepeatsTheFooter() async throws {
    engine.status = .success(status(indexed: true, count: 2))
    let studio = studio()
    studio.open(folder)
    try await wait("the folder and its index") { studio.library.count == 2 && studio.indexStatus != nil }

    studio.status = "2 images"
    XCTAssertNil(studio.footerMessage, "already shown as the image count")
    studio.status = "Ready to search"
    XCTAssertEqual(studio.footerMessage, "Ready to search")
    studio.status = ""
    XCTAssertNil(studio.footerMessage)
  }

  func testSettingsIsReachedFromTheFooterNotTheSidebar() {
    XCTAssertFalse(Page.sidebar.contains(.settings))
    XCTAssertEqual(Page.sidebar, [.library, .duplicates, .cleanup, .filter])
    XCTAssertTrue(Page.allCases.contains(.settings))
  }
}
