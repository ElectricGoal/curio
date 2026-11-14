import XCTest

@testable import LumaKit

final class ProgressEstimatorTests: XCTestCase {
  private final class Clock {
    var now = Date(timeIntervalSince1970: 100)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
  }

  private func estimator(loaded: Bool = false, expected: Int? = 1000) -> (IndexProgressEstimator, Clock) {
    let clock = Clock()
    let timing = ModelTiming(loadSeconds: 30, imagesPerSecond: 20)
    return (IndexProgressEstimator(timing: timing, modelLoaded: loaded, expected: expected, now: { clock.now }), clock)
  }

  func testEstimateExistsFromTheFirstMoment() {
    var (progress, _) = estimator()
    let first = progress.scanning()
    XCTAssertEqual(first.fraction, 0)
    XCTAssertEqual(first.eta ?? 0, 80.8, accuracy: 1.5)  // 30 load + 50 embed + scan and save
    XCTAssertTrue(first.ceiling > 0 && first.ceiling < 0.05)
  }

  func testWithoutAHintTheScanMakesNoGuess() {
    var (progress, _) = estimator(expected: nil)
    XCTAssertEqual(progress.scanning(), .start)
  }

  func testLoadingTheModelIsPartOfTheBar() {
    var (progress, clock) = estimator()
    _ = progress.scanning()
    clock.advance(1)
    let loading = progress.loading(total: 1000)
    XCTAssertEqual(loading.eta ?? 0, 80.3, accuracy: 0.01)
    XCTAssertEqual(loading.fraction, 1 / 81.3, accuracy: 0.001)
    XCTAssertEqual(loading.ceiling, 31 / 81.3, accuracy: 0.001, "the bar may glide through the load only")
  }

  func testEmbeddingSwitchesToTheMeasuredRate() {
    var (progress, clock) = estimator(loaded: true)
    progress.embeddingStarted()
    clock.advance(0.2)
    XCTAssertEqual(progress.embedding(processed: 8, total: 1000).eta ?? 0, 992 / 20 + 0.3, accuracy: 0.01)
    XCTAssertNil(progress.measuredRate, "8 images is noise, not a rate")

    clock.advance(49.8)  // 400 images in 50 s: 8 per second
    let slow = progress.embedding(processed: 400, total: 1000)
    XCTAssertEqual(progress.measuredRate ?? 0, 8, accuracy: 0.001)
    XCTAssertEqual(slow.eta ?? 0, 600 / 8 + 0.3, accuracy: 0.01)
    XCTAssertEqual(slow.fraction, 50 / (50 + 75.3), accuracy: 0.001)
  }

  func testTheBarNeverMovesBackwardsOrClaimsToBeFinished() {
    var (progress, clock) = estimator(loaded: true)
    progress.embeddingStarted()
    clock.advance(10)
    let before = progress.embedding(processed: 900, total: 1000)
    // The pace collapses: far more time left than a moment ago.
    clock.advance(100)
    let after = progress.embedding(processed: 901, total: 1000)
    XCTAssertGreaterThanOrEqual(after.fraction, before.fraction)

    clock.advance(1000)
    let saving = progress.saving()
    XCTAssertLessThan(saving.fraction, 1)
    XCTAssertGreaterThanOrEqual(saving.ceiling, saving.fraction)
  }

  func testRateProgressEstimatesFromThePaceSoFar() {
    let clock = Clock()
    var progress = RateProgressEstimator(now: { clock.now })
    XCTAssertNil(progress.at(done: 0, of: 1000).eta)
    clock.advance(10)
    let quarter = progress.at(done: 250, of: 1000)
    XCTAssertEqual(quarter.fraction, 0.25)
    XCTAssertEqual(quarter.eta ?? 0, 30, accuracy: 0.001)
    XCTAssertEqual(progress.at(done: 1000, of: 1000, finishing: 0.1).fraction, 0.9, accuracy: 1e-9)
  }

  func testTimingsPersistAndSurviveACorruptFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("timings.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = TimingStore(url: url)
    XCTAssertEqual(store.timing(for: "m"), .untimed)

    store.record("m", loadSeconds: 2.5)
    store.record("m", imagesPerSecond: 44)
    XCTAssertEqual(TimingStore(url: url).timing(for: "m"), ModelTiming(loadSeconds: 2.5, imagesPerSecond: 44))

    try Data("{ not json".utf8).write(to: url)
    XCTAssertEqual(store.timing(for: "m"), .untimed)
  }
}

final class DuplicateFinderTests: XCTestCase {
  private func unit(_ values: [Float]) -> [Float] { VectorMath.normalized(values) }

  private func snapshot(_ rows: [(String, [Float])]) -> IndexSnapshot {
    IndexSnapshot(
      modelAlias: "test-model", paths: rows.map(\.0), matrix: rows.flatMap { unit($0.1) }, dimension: rows[0].1.count)
  }

  func testLookAlikesClusterAndUnrelatedImagesDoNot() throws {
    let index = snapshot([
      ("a.jpg", [1, 0, 0]), ("a-small.jpg", [1, 0.01, 0]), ("b.jpg", [0, 1, 0]),
      ("a-edit.jpg", [1, 0, 0.02]), ("c.jpg", [0, 0, 1]),
    ])
    let groups = try DuplicateFinder.nearGroups(in: index, threshold: 0.999)
    XCTAssertEqual(groups.map(\.paths), [["a-edit.jpg", "a-small.jpg", "a.jpg"]])
    XCTAssertGreaterThan(groups[0].similarity, 0.999)
  }

  func testResultDoesNotDependOnBlockSize() throws {
    let rows = (0..<12).map { index -> (String, [Float]) in
      ("img\(index).jpg", [Float(index % 4 == 0 ? 1 : 0), Float(index % 4 == 1 ? 1 : 0), Float(index % 4 == 2 ? 1 : 0), Float(index % 4 == 3 ? 1 : 0)])
    }
    let index = snapshot(rows)
    var reported: [Int] = []
    let whole = try DuplicateFinder.nearGroups(in: index, threshold: 0.99)
    let oneRowAtATime = try DuplicateFinder.nearGroups(in: index, threshold: 0.99, blockCells: 12, onProgress: { done, _ in reported.append(done) })
    XCTAssertEqual(whole.map(\.paths), oneRowAtATime.map(\.paths))
    XCTAssertEqual(whole.count, 4)
    XCTAssertEqual(reported, Array(1...12), "progress is reported after every block")
  }

  func testAClusterReportsItsClosestPairHoweverItIsSplitIntoBlocks() throws {
    // a–b are nearly identical; c joins the cluster through a looser match.
    let index = snapshot([("a.jpg", [1, 0, 0]), ("b.jpg", [1, 0.001, 0]), ("c.jpg", [1, 0.1, 0]), ("z.jpg", [0, 0, 1])])
    let closest = Double(VectorMath.dot(unit([1, 0, 0]), unit([1, 0.001, 0])))
    for blockCells in [DuplicateFinder.blockCells, 4] {
      let groups = try DuplicateFinder.nearGroups(in: index, threshold: 0.99, blockCells: blockCells)
      XCTAssertEqual(groups.map(\.paths), [["a.jpg", "b.jpg", "c.jpg"]])
      XCTAssertEqual(groups[0].similarity, closest, accuracy: 1e-6)
    }
  }

  func testComparingStopsBetweenBlocksWhenCancelled() {
    let rows = (0..<12).map { ("img\($0).jpg", [Float(1), Float($0), 0]) }
    var blocks = 0
    XCTAssertThrowsError(
      try DuplicateFinder.nearGroups(
        in: snapshot(rows), threshold: 0.99, blockCells: 12, isCancelled: { blocks >= 3 },
        onProgress: { _, _ in blocks += 1 })
    ) { XCTAssertEqual($0 as? EngineError, .cancelled) }
    XCTAssertEqual(blocks, 3, "no further block is compared after the cancel")
  }

  func testIdenticalAndLookAlikeGroupsMerge() {
    let groups = DuplicateFinder.groups(
      identical: [["a.jpg", "copy of a.jpg"]],
      near: [(paths: ["a.jpg", "a-small.jpg"], similarity: 0.99), (paths: ["x.jpg", "y.jpg"], similarity: 0.97)],
      size: { ["a.jpg": 30, "copy of a.jpg": 30, "a-small.jpg": 5, "x.jpg": 9, "y.jpg": 8][$0] ?? 0 })

    XCTAssertEqual(groups.count, 2)
    XCTAssertTrue(groups[0].isExact)
    XCTAssertEqual(groups[0].similarity, 1)
    XCTAssertEqual(groups[0].keeper, "a.jpg", "same size: the one that is not a copy is kept")
    XCTAssertEqual(groups[0].duplicates, ["a-small.jpg", "copy of a.jpg"])
    XCTAssertFalse(groups[1].isExact)
    XCTAssertEqual(groups[1].keeper, "x.jpg", "the larger file is kept")
  }

  func testKeeperPrefersTheOriginalWhenFilesTie() {
    for copy in ["copy of beach.jpg", "beach copy.jpg", "beach copy 2.jpg", "beach (1).jpg", "Beach Copy.jpg"] {
      for order in [[copy, "beach.jpg"], ["beach.jpg", copy]] {
        XCTAssertEqual(DuplicateFinder.keeper(among: order, size: { _ in 10 }), "beach.jpg", copy)
      }
    }
    XCTAssertEqual(
      DuplicateFinder.keeper(among: ["exports/IMG_1.jpg", "IMG_1.jpg"], size: { _ in 10 }), "IMG_1.jpg",
      "then the shorter path")
    XCTAssertEqual(
      DuplicateFinder.keeper(among: ["beach.jpg", "beach copy.jpg"], size: { $0.contains("copy") ? 100 : 10 }),
      "beach copy.jpg", "size still wins over the name")
  }
}
