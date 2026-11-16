import XCTest

@testable import CurioKit

/// Stand-in model: an image embeds as its average colour, a text as a named colour.
final class ColourModel: EmbeddingModel, @unchecked Sendable {
  static let colours: [String: [Float]] = [
    "red": [1, 0, 0], "green": [0, 1, 0], "blue": [0, 0, 1],
  ]

  let manifest: ModelManifest
  private let lock = NSLock()
  private var imageCalls = 0
  /// Called with the running count each time an image is embedded.
  var onImage: ((Int) -> Void)?

  init(alias: String = "clip-vit-b32") {
    manifest = IndexStoreTests.manifest(alias: alias, dim: 4)
  }

  var imagesEmbedded: Int { lock.withLock { imageCalls } }

  func embed(image tensor: [Float]) async throws -> [Float] {
    let count = lock.withLock { () -> Int in
      imageCalls += 1
      return imageCalls
    }
    onImage?(count)
    let plane = tensor.count / 3
    let mean = (0..<3).map { channel in
      tensor[(channel * plane)..<((channel + 1) * plane)].reduce(0, +) / Float(plane)
    }
    return VectorMath.normalized(mean + [0.05])
  }

  func embed(text: String) async throws -> [Float] {
    VectorMath.normalized((Self.colours[text.lowercased()] ?? [0.5, 0.5, 0.5]) + [0.05])
  }
}

final class NativeEngineTests: XCTestCase {
  private var root: URL!
  private var photos: URL!
  private var model: ColourModel!
  private var loads: Locked<[String]>!
  private var engine: NativeEngine!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("curio-" + UUID().uuidString)
    photos = root.appendingPathComponent("photos")
    try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
    model = ColourModel()
    loads = Locked([])
    engine = makeEngine()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func makeEngine() -> NativeEngine {
    let model = model!
    let loads = loads!
    return NativeEngine(dataRoot: root.appendingPathComponent("data")) { alias in
      loads.update { $0.append(alias) }
      return alias == model.manifest.alias ? model : ColourModel(alias: alias)
    }
  }

  private func paint(_ name: String, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int = 32) throws {
    let url = photos.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try EmbeddingModelTests.writePNG(to: url, width: width, height: 24, red: red, green: green, blue: blue)
  }

  /// Two reds, two greens, two blues; the copies differ in size, not in colour.
  private func paintSix() throws {
    try paint("red.png", 1, 0, 0)
    try paint("red-copy.png", 1, 0, 0, width: 48)
    try paint("green.png", 0, 1, 0)
    try paint("sub/green-copy.png", 0, 1, 0, width: 48)
    try paint("blue.png", 0, 0, 1)
    try paint("blue-copy.png", 0, 0, 1, width: 48)
  }

  @discardableResult
  private func index(rebuild: Bool = false, model alias: String = "clip-vit-b32") async throws -> IndexResponse {
    try await engine.index(folder: photos, model: alias, rebuild: rebuild, expected: nil) { _ in }
  }

  // MARK: - Status and indexing

  func testStatusFollowsTheFolderThroughIndexingAndChanges() async throws {
    try paintSix()
    var status = try await engine.status(folder: photos)
    XCTAssertEqual([status.indexed, false], [false, false])
    XCTAssertEqual([status.total, status.pending, status.count], [6, 6, 0])

    let result = try await index()
    XCTAssertEqual([result.count, result.added, result.skipped, result.remaining], [6, 6, 0, 0])
    XCTAssertFalse(result.cancelled)
    status = try await engine.status(folder: photos)
    XCTAssertTrue(status.indexed)
    XCTAssertEqual([status.count, status.pending, status.missing], [6, 0, 0])
    XCTAssertEqual(status.model, "clip-vit-b32")
    XCTAssertEqual(status.modelAvailable, true)
    XCTAssertFalse(status.needsRebuild)

    try paint("new.png", 1, 0, 0)
    try FileManager.default.removeItem(at: photos.appendingPathComponent("blue.png"))
    status = try await engine.status(folder: photos)
    XCTAssertEqual([status.total, status.pending, status.missing], [6, 1, 1])
  }

  func testUpdateOnlyEmbedsWhatChanged() async throws {
    try paintSix()
    try await index()
    XCTAssertEqual(model.imagesEmbedded, 6)

    try paint("later.png", 0, 0, 1)
    try FileManager.default.removeItem(at: photos.appendingPathComponent("red.png"))
    let update = try await index()

    XCTAssertEqual([update.count, update.added, update.removed], [6, 1, 1])
    XCTAssertEqual(model.imagesEmbedded, 7, "unchanged images are not embedded again")
    XCTAssertEqual(loads.update { $0 }, ["clip-vit-b32"], "the model is loaded once and kept")
  }

  func testATouchedButUnchangedFileIsNotEmbeddedAgain() async throws {
    try paintSix()
    try await index()
    let url = photos.appendingPathComponent("red.png")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)

    let update = try await index()

    XCTAssertEqual(update.added, 0)
    XCTAssertEqual(model.imagesEmbedded, 6)
    let pending = try await engine.status(folder: photos).pending
    XCTAssertEqual(pending, 0)
  }

  func testUnreadableFilesAreCountedOnceAndNotRetried() async throws {
    try paintSix()
    try Data("this is not a jpeg".utf8).write(to: photos.appendingPathComponent("broken.jpg"))

    let first = try await index()
    XCTAssertEqual([first.count, first.skipped], [6, 1])
    let status = try await engine.status(folder: photos)
    XCTAssertEqual([status.pending, status.unreadable], [0, 1])

    let second = try await index()
    XCTAssertEqual(second.skipped, 0, "it has not changed, so it is not tried again")
  }

  func testAFileDeletedWhileIndexingIsNotRememberedAsUnreadable() async throws {
    for number in 0..<20 { try paint("img\(String(format: "%02d", number)).png", 1, 0, 0) }
    let doomed = photos.appendingPathComponent("img19.png")
    model.onImage = { count in if count == 1 { try? FileManager.default.removeItem(at: doomed) } }

    let result = try await index()

    XCTAssertEqual([result.count, result.skipped], [19, 0])
    let store = try IndexStore(url: IndexStore.location(in: photos))
    defer { store.close() }
    XCTAssertEqual(try store.skipped().keys.sorted(), [], "a file that is gone is not an unreadable file")
  }

  func testAFileThatCannotBeOpenedIsSkippedButTheRestAreIndexed() async throws {
    try paintSix()
    let locked = photos.appendingPathComponent("red.png")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

    let result = try await index()

    XCTAssertEqual([result.count, result.skipped], [5, 1])
    let status = try await engine.status(folder: photos)
    XCTAssertEqual([status.pending, status.unreadable], [0, 1])
  }

  func testIndexingStopsWithAnExplanationWhenTheFolderDisappears() async throws {
    for number in 0..<20 { try paint("img\(number).png", 1, 0, 0) }
    let photos = photos!
    let away = root.appendingPathComponent("unplugged")
    // Like a drive being unplugged part-way: after the first batch nothing can be read.
    model.onImage = { count in if count == 8 { try? FileManager.default.moveItem(at: photos, to: away) } }

    do {
      try await index()
      XCTFail("expected indexing to stop")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("can no longer be reached"), "\(error)")
    }
    try FileManager.default.moveItem(at: away, to: photos)
    let store = try IndexStore(url: IndexStore.location(in: photos))
    defer { store.close() }
    XCTAssertEqual(try store.skipped().count, 0, "files on a missing drive are not written off as unreadable")
    XCTAssertEqual(try store.count(), 8, "what was finished before it went away is kept")
  }

  func testAModelCannotBeRemovedWhileIndexingIsUsingIt() async throws {
    for number in 0..<20 { try paint("img\(number).png", 1, 0, 0) }
    model.onImage = { _ in Thread.sleep(forTimeInterval: 0.01) }
    let engine = engine!
    let photos = photos!
    let model = model!
    let task = Task { try await engine.index(folder: photos, model: "clip-vit-b32", rebuild: false, expected: 20) { _ in } }
    while model.imagesEmbedded == 0 { try await Task.sleep(for: .milliseconds(2)) }

    do {
      _ = try await engine.deleteModel("clip-vit-b32")
      XCTFail("expected the removal to be refused")
    } catch {
      guard case EngineError.busy = error else { return XCTFail("expected busy, got \(error)") }
    }
    let finished = try await task.value
    XCTAssertEqual(finished.count, 20)
  }

  func testTwoModelsWantedAtOnceAreLoadedOneAfterTheOtherNotSwappedMidIndex() async throws {
    try paintSix()
    try await index(model: "clip-vit-b32")
    // A second folder indexed with the other model, while the first is being searched.
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try EmbeddingModelTests.writePNG(to: other.appendingPathComponent("x.png"), width: 32, height: 24, red: 0, green: 0, blue: 1)
    let engine = engine!
    let photos = photos!
    async let indexed = engine.index(folder: other, model: "mobileclip-s4", rebuild: false, expected: 1) { _ in }
    let searching = Task { try await engine.search(folder: photos, text: "red", limit: 1) { _ in } }

    let response = try await indexed
    XCTAssertEqual([response.model, String(response.count)], ["mobileclip-s4", "1"])
    // The search either ran before the index took the model, or was told to wait: never wrong results.
    switch await searching.result {
    case .success(let results): XCTAssertEqual(results.images.first?.name.hasPrefix("red"), true)
    case .failure(let error):
      guard case EngineError.busy = error else { return XCTFail("unexpected \(error)") }
    }
  }

  func testPausingKeepsFinishedBatchesAndResumingFinishesTheRest() async throws {
    for number in 0..<20 { try paint("img\(number).png", 1, 0, 0) }
    let running = Locked<Task<IndexResponse, Error>?>(nil)
    model.onImage = { count in if count == 1 { running.update { $0?.cancel() } } }
    let engine = engine!
    let photos = photos!
    let task = Task { try await engine.index(folder: photos, model: "clip-vit-b32", rebuild: false, expected: 20) { _ in } }
    running.update { $0 = task }

    let paused = try await task.value
    XCTAssertTrue(paused.cancelled)
    XCTAssertEqual([paused.count, paused.remaining], [8, 12], "the batch in progress is completed and saved")
    let status = try await engine.status(folder: photos)
    XCTAssertEqual([status.count, status.pending], [8, 12])

    model.onImage = nil
    let resumed = try await index()
    XCTAssertEqual([resumed.count, resumed.added], [20, 12])
    XCTAssertEqual(model.imagesEmbedded, 20, "nothing was embedded twice")
  }

  func testACancelledRebuildLeavesThePreviousIndexUntouched() async throws {
    for number in 0..<20 { try paint("img\(number).png", 0, 1, 0) }
    try await index()
    let before = try await engine.search(folder: photos, text: "green", limit: 5) { _ in }

    let running = Locked<Task<IndexResponse, Error>?>(nil)
    model.onImage = { count in if count == 21 { running.update { $0?.cancel() } } }
    let engine = engine!
    let photos = photos!
    let task = Task { try await engine.index(folder: photos, model: "clip-vit-b32", rebuild: true, expected: 20) { _ in } }
    running.update { $0 = task }
    do {
      _ = try await task.value
      XCTFail("a cancelled rebuild must not report success")
    } catch {
      XCTAssertEqual(error as? EngineError, .cancelled)
    }

    let status = try await engine.status(folder: photos)
    XCTAssertEqual(status.count, 20, "the old index is still complete")
    let after = try await engine.search(folder: photos, text: "green", limit: 5) { _ in }
    XCTAssertEqual(after.images.map(\.path), before.images.map(\.path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: IndexStore.directory(in: photos).path)
      .filter { $0.contains("rebuild") }
    XCTAssertEqual(leftovers, [])
  }

  func testRebuildSwitchesModelAndAnUpdateKeepsTheIndexModel() async throws {
    try paintSix()
    try await index(model: "clip-vit-b32")
    // The app's selection changed, but an update must continue with the index's model.
    let update = try await index(model: "mobileclip-s4")
    XCTAssertEqual(update.model, "clip-vit-b32")

    let rebuilt = try await index(rebuild: true, model: "mobileclip-s4")
    XCTAssertEqual([rebuilt.model, String(rebuilt.count)], ["mobileclip-s4", "6"])
    let alias = try await engine.status(folder: photos).model
    XCTAssertEqual(alias, "mobileclip-s4")
  }

  func testProgressRunsFromZeroTowardsOneThroughEveryPhase() async throws {
    try paintSix()
    let reports = Locked<[EngineProgress]>([])
    _ = try await engine.index(folder: photos, model: "clip-vit-b32", rebuild: false, expected: 6) { progress in
      reports.update { $0.append(progress) }
    }
    let all = reports.update { $0 }
    XCTAssertEqual(all.map(\.message), ["Scanning images", "Loading model", "Indexing images", "Indexing images", "Saving search index"])
    let fractions = all.compactMap(\.fraction)
    XCTAssertEqual(fractions.count, all.count, "every phase is on the bar")
    XCTAssertEqual(fractions.first, 0)
    XCTAssertEqual(fractions, fractions.sorted(), "the bar never moves backwards")
    XCTAssertTrue(fractions.allSatisfy { $0 < 1 })
    XCTAssertTrue(all.allSatisfy { $0.eta != nil }, "every phase has a time estimate")
    XCTAssertEqual(all.filter { $0.total != nil }.map { [$0.current ?? -1, $0.total ?? -1] }, [[0, 6], [6, 6]])
  }

  // MARK: - Search and duplicates

  func testTextAndImageSearchRankMatchingColoursFirst() async throws {
    try paintSix()
    try await index()

    let green = try await engine.search(folder: photos, text: " Green ", limit: 2) { _ in }
    XCTAssertEqual(Set(green.images.map(\.name)), ["green.png", "green-copy.png"])
    XCTAssertEqual(green.model, "clip-vit-b32")
    XCTAssertGreaterThan(try XCTUnwrap(green.images.first?.similarity), 0.99)

    let reference = photos.appendingPathComponent("blue.png").path
    let similar = try await engine.search(folder: photos, similarTo: reference, limit: 2) { _ in }
    XCTAssertEqual(Set(similar.images.map(\.name)), ["blue.png", "blue-copy.png"])
  }

  func testSearchSkipsFilesThatHaveSinceBeenDeleted() async throws {
    try paintSix()
    try await index()
    try FileManager.default.removeItem(at: photos.appendingPathComponent("green.png"))
    let green = try await engine.search(folder: photos, text: "green", limit: 2) { _ in }
    XCTAssertFalse(green.images.contains { $0.name == "green.png" })
  }

  func testSearchingBeforeIndexingExplainsWhatToDo() async throws {
    try paintSix()
    do {
      _ = try await engine.search(folder: photos, text: "red", limit: 5) { _ in }
      XCTFail("expected an error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("has not been indexed"))
    }
    XCTAssertFalse(IndexStore.exists(in: photos), "a failed search must not create an index")
  }

  func testDuplicatesGroupCopiesAndKeepOneOfEach() async throws {
    try paintSix()
    let twin = photos.appendingPathComponent("copy of red.png")
    try FileManager.default.copyItem(at: photos.appendingPathComponent("red.png"), to: twin)
    try await index()

    let exact = try await engine.duplicates(folder: photos, threshold: 1, exactOnly: true) { _ in }
    XCTAssertEqual(exact.groups.map(\.kind), ["exact"])
    XCTAssertEqual(exact.groups[0].files.first { $0.keep == true }?.name, "red.png", "the original is kept")

    let near = try await engine.duplicates(folder: photos, threshold: 0.99, exactOnly: false) { _ in }
    XCTAssertEqual(near.groups.count, 3)
    XCTAssertEqual(near.redundant, 4)
    for group in near.groups {
      XCTAssertEqual(group.files.filter { $0.keep == true }.count, 1)
      XCTAssertEqual(group.files.first?.keep, true)
    }
    XCTAssertEqual(near.reclaimable, near.groups.flatMap { $0.files.filter { $0.keep == false } }.reduce(0) { $0 + $1.size })
  }

  // MARK: - Indexes from other versions

  func testAnIndexFromThePythonAppAsksForARebuildAndIsReplacedByOne() async throws {
    try paintSix()
    let directory = IndexStore.directory(in: photos)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data().write(to: directory.appendingPathComponent("index.faiss"))
    try Data().write(to: directory.appendingPathComponent("meta.db"))
    try Data(#"{"version":1,"model_alias":"mobileclip-s4"}"#.utf8).write(to: directory.appendingPathComponent("manifest.json"))

    let status = try await engine.status(folder: photos)
    XCTAssertTrue(status.needsRebuild)
    XCTAssertTrue(status.rebuildReason?.contains("earlier version") ?? false)
    do {
      _ = try await engine.search(folder: photos, text: "red", limit: 1) { _ in }
      XCTFail("expected an error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Rebuild"))
    }

    try await index(rebuild: true)
    let rebuilt = try await engine.status(folder: photos)
    XCTAssertFalse(rebuilt.needsRebuild)
    XCTAssertEqual(rebuilt.count, 6)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.faiss").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meta.db").path))
  }
}

final class ModelLibraryTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("curio-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// A minimal hosted model: a manifest and one "weights" file, with a listing.
  private func host(
    _ alias: String, corrupt: Bool = false, escaping: Bool = false, manifestAlias: String? = nil,
    listedSizeOffset: Int = 0, weights: UInt8 = 7
  ) throws -> URL {
    let remote = root.appendingPathComponent("remote")
    let directory = remote.appendingPathComponent(alias)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("image.mlpackage"), withIntermediateDirectories: true)
    let manifest = IndexStoreTests.manifest(alias: manifestAlias ?? alias)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let files: [(String, Data)] = [
      ("model.json", try encoder.encode(manifest)),
      ("image.mlpackage/weights.bin", Data(repeating: weights, count: 50_000)),
    ]
    var listing: [[String: Any]] = []
    for (path, data) in files {
      try data.write(to: directory.appendingPathComponent(path))
      let written = directory.appendingPathComponent(path)
      listing.append([
        "path": escaping && path == "model.json" ? "../model.json" : path,
        "size": data.count + listedSizeOffset,
        "sha256": corrupt ? String(repeating: "0", count: 64) : try ModelLibrary.sha256(of: written),
      ])
    }
    try JSONSerialization.data(withJSONObject: listing).write(to: directory.appendingPathComponent("files.json"))
    return remote
  }

  private func library(remote: URL? = nil, bundled: URL? = nil) -> ModelLibrary {
    ModelLibrary(installDirectory: root.appendingPathComponent("installed"), bundledDirectory: bundled, remote: remote)
  }

  func testCatalogListsBothModelsWithOneDefault() {
    let models = library().models()
    XCTAssertEqual(models.map(\.alias), ["mobileclip-s4", "clip-vit-b32"])
    XCTAssertEqual(models.filter(\.isDefault).map(\.alias), ["mobileclip-s4"])
    XCTAssertTrue(models.allSatisfy { !$0.installed && !$0.available }, "nothing installed and nowhere to get it")
    XCTAssertTrue(models[0].availabilityMessage.contains("convert-models.sh"))
  }

  func testDownloadVerifiesInstallsAndReportsBytes() async throws {
    let remote = try host("clip-vit-b32")
    let library = library(remote: remote)
    XCTAssertTrue(library.models()[1].available, "a host makes it obtainable")
    let reports = Locked<[[Int64]]>([])

    try await library.install("clip-vit-b32") { done, total in reports.update { $0.append([done, total]) } }

    let model = library.models()[1]
    XCTAssertTrue(model.installed)
    XCTAssertGreaterThan(model.size, 50_000)
    XCTAssertNotNil(library.directory(for: "clip-vit-b32"))
    let all = reports.update { $0 }
    XCTAssertEqual(all.first?[0], 0)
    XCTAssertEqual(all.last?[0], all.last?[1], "ends at the total")
    XCTAssertEqual(all.map { $0[0] }, all.map { $0[0] }.sorted())

    try library.remove("clip-vit-b32")
    XCTAssertFalse(library.models()[1].installed)
  }

  func testDamagedDownloadIsRejectedAndLeavesNothingBehind() async throws {
    let library = library(remote: try host("clip-vit-b32", corrupt: true))
    do {
      try await library.install("clip-vit-b32") { _, _ in }
      XCTFail("expected a checksum failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("damaged"))
    }
    XCTAssertFalse(library.models()[1].installed)
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: library.installDirectory.path)) ?? []
    XCTAssertEqual(leftovers, [], "no partial model and no staging folder")
  }

  func testListingCannotWriteOutsideTheModelFolder() async throws {
    let library = library(remote: try host("clip-vit-b32", escaping: true))
    do {
      try await library.install("clip-vit-b32") { _, _ in }
      XCTFail("expected the listing to be rejected")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("not valid"))
    }
  }

  func testCancellingADownloadStopsItAndInstallsNothing() async throws {
    let library = library(remote: try host("clip-vit-b32"))
    // Cancelled before it starts and cancelled part-way must both end the same way.
    for cancelAfterFirstReport in [false, true] {
      let running = Locked<Task<Void, Error>?>(nil)
      let task = Task {
        try await library.install("clip-vit-b32") { done, _ in
          if cancelAfterFirstReport, done > 0 { running.update { $0?.cancel() } }
        }
      }
      running.update { $0 = task }
      if !cancelAfterFirstReport { task.cancel() }
      do {
        try await task.value
        XCTFail("a cancelled download must not report success")
      } catch {
        XCTAssertEqual(error as? EngineError, .cancelled, "\(error)")
      }
      XCTAssertFalse(library.models()[1].installed)
    }
  }

  func testFilesUnderTheWrongModelNameAreRejected() async throws {
    let library = library(remote: try host("clip-vit-b32", manifestAlias: "mobileclip-s4"))
    do {
      try await library.install("clip-vit-b32") { _, _ in }
      XCTFail("expected the download to be rejected")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("not valid"), "\(error)")
    }
    XCTAssertFalse(library.models()[1].installed)
  }

  func testAFileThatIsNotTheListedSizeIsRejected() async throws {
    let library = library(remote: try host("clip-vit-b32", listedSizeOffset: 5))
    do {
      try await library.install("clip-vit-b32") { _, _ in }
      XCTFail("expected the download to be rejected")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("damaged"), "\(error)")
    }
  }

  func testAFailedReinstallKeepsTheModelThatWasWorking() async throws {
    try await library(remote: try host("clip-vit-b32")).install("clip-vit-b32") { _, _ in }
    let broken = library(remote: try host("clip-vit-b32", corrupt: true, weights: 9))

    do {
      try await broken.install("clip-vit-b32") { _, _ in }
      XCTFail("expected a checksum failure")
    } catch {}

    let directory = try XCTUnwrap(broken.directory(for: "clip-vit-b32"))
    let weights = try Data(contentsOf: directory.appendingPathComponent("image.mlpackage/weights.bin"))
    XCTAssertEqual(weights.first, 7, "still the first, intact copy")
  }

  func testAnInterruptedDownloadsLeftoversAreClearedByTheNextOne() async throws {
    let library = library(remote: try host("clip-vit-b32"))
    let orphan = library.installDirectory.appendingPathComponent(".download-clip-vit-b32-old")
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 10).write(to: orphan.appendingPathComponent("partial"))

    try await library.install("clip-vit-b32") { _, _ in }

    let contents = try FileManager.default.contentsOfDirectory(atPath: library.installDirectory.path)
    XCTAssertEqual(contents, ["clip-vit-b32"])
  }

  func testAManifestWithImpossibleValuesIsRejected() throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let good = IndexStoreTests.manifest()
    func manifest(dim: Int = 3, imageSize: Int = 8, contextLength: Int = 77, merges: String = "bpe_merges.txt") -> ModelManifest {
      ModelManifest(
        format: 1, alias: good.alias, name: good.name, dim: dim, imageSize: imageSize, contextLength: contextLength,
        padToken: 0, startToken: 49406, endToken: 49407, precision: "float16", license: "MIT",
        imageModel: "image.mlpackage", textModel: "text.mlpackage", merges: merges)
    }
    let directory = root.appendingPathComponent("model")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cases = [
      manifest(dim: 0), manifest(imageSize: 0), manifest(imageSize: 1_000_000), manifest(contextLength: 0),
      manifest(merges: "../../somewhere/else.txt"),
    ]
    for bad in cases {
      try encoder.encode(bad).write(to: directory.appendingPathComponent("model.json"))
      XCTAssertThrowsError(try ModelManifest.load(from: directory), "\(bad)") { error in
        XCTAssertTrue(error.localizedDescription.contains("incomplete or damaged"), "\(error)")
      }
    }
    try encoder.encode(good).write(to: directory.appendingPathComponent("model.json"))
    XCTAssertEqual(try ModelManifest.load(from: directory), good)
  }

  func testWithoutAHostDownloadExplainsHowToGetTheModel() async {
    do {
      try await library().install("mobileclip-s4") { _, _ in }
      XCTFail("expected an error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("convert-models.sh"))
    }
  }

  func testBundledModelsAreUsableButNotRemovable() throws {
    let bundled = root.appendingPathComponent("bundle")
    let directory = bundled.appendingPathComponent("clip-vit-b32")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    try encoder.encode(IndexStoreTests.manifest(alias: "clip-vit-b32")).write(to: directory.appendingPathComponent("model.json"))
    let library = library(bundled: bundled)

    let model = library.models()[1]
    XCTAssertTrue(model.installed && model.available)
    XCTAssertEqual(model.size, 0, "nothing the user could free")
    XCTAssertThrowsError(try library.remove("clip-vit-b32")) { error in
      XCTAssertTrue(error.localizedDescription.contains("part of the app"))
    }
    XCTAssertTrue(library.models()[1].installed)
  }
}
