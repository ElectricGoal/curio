import Foundation
import XCTest

@testable import LumaKit

final class ActivityTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1000)

  private func after(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  private func indexing(
    _ fraction: Double, eta: Double?, ceiling: Double, current: Int? = nil, total: Int? = nil
  ) -> EngineProgress {
    EngineProgress(
      message: "Indexing images", current: current, total: total, unit: total == nil ? nil : .images,
      fraction: fraction, eta: eta, ceiling: ceiling)
  }

  func testBarStartsAtZeroWithAnHonestEstimatingLabel() {
    let activity = Activity(id: "1", kind: .indexing, startedAt: start)

    XCTAssertEqual(activity.progress(at: after(5)), 0)
    XCTAssertNil(activity.secondsRemaining(at: after(5)))
    XCTAssertEqual(activity.detail(now: after(5)), "0% · estimating time…")
  }

  func testBarGlidesBetweenUpdatesAtTheEstimatedPace() {
    // 10% done, 90 s left: one second is worth one percent of the whole.
    let activity = Activity(id: "1", kind: .indexing, startedAt: start)
      .applying(indexing(0.10, eta: 90, ceiling: 0.40), now: start)

    XCTAssertEqual(activity.progress(at: start), 0.10, accuracy: 0.0001)
    XCTAssertEqual(activity.progress(at: after(10)), 0.20, accuracy: 0.0001)
    XCTAssertEqual(activity.secondsRemaining(at: after(10)) ?? 0, 80, accuracy: 0.0001)
    XCTAssertEqual(activity.detail(now: after(10)), "20% · about 1 min left")
  }

  func testBarWaitsAtThePhaseBoundaryWhenAPhaseRunsLong() {
    let activity = Activity(id: "1", kind: .indexing, startedAt: start)
      .applying(indexing(0.10, eta: 90, ceiling: 0.40), now: start)

    // The phase should have ended after 30 s; a minute in, the bar has not run ahead.
    XCTAssertEqual(activity.progress(at: after(60)), 0.40, accuracy: 0.0001)
    XCTAssertEqual(activity.secondsRemaining(at: after(60)) ?? 0, 60, accuracy: 0.0001)
    XCTAssertEqual(activity.detail(now: after(60)), "40% · taking longer than usual…")
    XCTAssertEqual(activity.detail(now: after(31)), "40% · about 1 min left", "a small overrun is not news")
  }

  func testBarNeverMovesBackwards() {
    let activity = Activity(id: "1", kind: .indexing, startedAt: start)
      .applying(indexing(0.10, eta: 90, ceiling: 0.40), now: start)
      // Ten seconds on the bar shows 20%, but the engine has revised down to 15%.
      .applying(indexing(0.15, eta: 170, ceiling: 0.9), now: after(10))

    XCTAssertEqual(activity.progress(at: after(10)), 0.20, accuracy: 0.0001)
    XCTAssertGreaterThan(activity.progress(at: after(20)), 0.20)
    XCTAssertEqual(activity.secondsRemaining(at: after(10)) ?? 0, 170, accuracy: 0.0001)
  }

  func testCountsAreShownAlongsideTheOverallPercentage() {
    let activity = Activity(id: "1", kind: .indexing, startedAt: start)
      .applying(indexing(0.5, eta: 120, ceiling: 0.98, current: 300, total: 1200), now: start)

    XCTAssertEqual(
      activity.detail(now: start),
      "300 of \(Format.count(1200)) images · 50% · about 2 min left")  // grouping follows the locale
    XCTAssertEqual(
      activity.cancelling().detail(now: start), "300 of \(Format.count(1200)) images · 50%")
  }

  func testByteProgressUsesFileSizes() {
    let progress = EngineProgress(
      message: "Downloading", current: 500_000_000, total: 1_000_000_000, unit: .bytes,
      fraction: 0.495, eta: 42, ceiling: 0.495)
    let activity = Activity(id: "1", kind: .downloading(modelName: "M"), startedAt: start)
      .applying(progress, now: start)

    XCTAssertEqual(
      activity.detail(now: start),
      "\(Format.bytes(500_000_000)) of \(Format.bytes(1_000_000_000)) · 49% · about 45 sec left")
  }

  func testFinishedTaskShowsOneHundredPercent() {
    let activity = Activity(id: "1", kind: .indexing, startedAt: start)
      .applying(indexing(0.97, eta: 0.5, ceiling: 0.99), now: start)

    XCTAssertLessThan(activity.progress(at: after(600)), 1, "only finishing reaches the end")

    let done = activity.finished()
    XCTAssertEqual(done.progress(at: after(1)), 1)
    XCTAssertEqual(done.detail(now: after(1)), "100%")
    XCTAssertTrue(done.isFinished)
  }

  func testAProgressReportArrivingAfterTheEndDoesNotReopenTheBar() {
    let done = Activity(id: "1", kind: .indexing, startedAt: start).finished()

    let late = done.applying(indexing(0.6, eta: 20, ceiling: 0.7), now: after(1))

    XCTAssertTrue(late.isFinished)
    XCTAssertEqual(late.progress(at: after(2)), 1)
    XCTAssertEqual(late.detail(now: after(2)), "100%")
  }

  func testEngineWithoutAnOverallPositionFallsBackToCounts() {
    let legacy = EngineProgress(message: "Indexing images", current: 25, total: 100, unit: .images)
    let activity = Activity(id: "1", kind: .indexing, startedAt: start).applying(legacy, now: start)

    XCTAssertEqual(activity.progress(at: after(30)), 0.25, accuracy: 0.0001)
    XCTAssertEqual(activity.detail(now: after(30)), "25 of 100 images · 25% · estimating time…")
  }

  func testOnlyIndexingStopsCooperatively() {
    XCTAssertTrue(Activity.Kind.indexing.cancelsCooperatively)
    XCTAssertTrue(Activity.Kind.rebuilding.cancelsCooperatively)
    XCTAssertFalse(Activity.Kind.downloading(modelName: "M").cancelsCooperatively)
    XCTAssertFalse(Activity.Kind.downloading(modelName: "M").usesFolder)
    XCTAssertFalse(Activity.Kind.removingModel.canCancel)
  }
}

final class DuplicateTests: XCTestCase {
  private func record(_ name: String, size: Int64, keep: Bool) -> String {
    #"{"path":"/p/\#(name)","name":"\#(name)","size":\#(size),"modified":1,"keep":\#(keep)}"#
  }

  private func report() throws -> DuplicateReport {
    let json = """
      {"groups":[
        {"kind":"exact","similarity":1.0,"files":[\(record("a.jpg", size: 30, keep: true)),\(record("a2.jpg", size: 30, keep: false)),\(record("a3.jpg", size: 30, keep: false))]},
        {"kind":"similar","similarity":0.991,"files":[\(record("b.jpg", size: 50, keep: true)),\(record("b-small.jpg", size: 7, keep: false))]},
        {"kind":"similar","similarity":0.99,"files":[\(record("lonely.jpg", size: 5, keep: true))]}
      ],"redundant":3,"reclaimable":67,"threshold":0.98}
      """
    return DuplicateReport(try snakeCaseDecoder().decode(DuplicatesResponse.self, from: Data(json.utf8)))
  }

  func testReportSummarisesExtras() throws {
    let report = try report()
    XCTAssertEqual(report.sets.count, 2, "groups without a second file are dropped")
    XCTAssertEqual(report.extras.map(\.name), ["a2.jpg", "a3.jpg", "b-small.jpg"])
    XCTAssertEqual(report.reclaimableBytes, 67)
    XCTAssertEqual(report.sets[0].label, "Identical files")
    XCTAssertEqual(report.sets[1].label, "Look alike · 99% similar")
  }

  func testChoosingADifferentKeeper() throws {
    let report = try report().keeping("/p/b-small.jpg", in: 1)
    XCTAssertEqual(report.sets[1].extras.map(\.name), ["b.jpg"])
    XCTAssertEqual(report.reclaimableBytes, 110)
    XCTAssertEqual(try self.report().keeping("/p/elsewhere.jpg", in: 1), try self.report())
  }

  func testRemovingTrashedFilesShrinksOrDropsSets() throws {
    let report = try report().removing(["/p/a.jpg", "/p/b-small.jpg"])
    XCTAssertEqual(report.sets.count, 1)
    XCTAssertEqual(report.sets[0].keeperPath, "/p/a2.jpg", "a new keeper is chosen when the old one is gone")
    XCTAssertEqual(report.sets[0].extras.map(\.name), ["a3.jpg"])
  }

  func testTrashMovesFilesAndReportsFailures() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("luma-test-duplicate.jpg")
    try Data("x".utf8).write(to: file)
    var resulting: NSURL?
    // Probe whether this environment has a Trash at all (CI sandboxes may not).
    let probe = directory.appendingPathComponent("probe.jpg")
    try Data("x".utf8).write(to: probe)
    guard (try? FileManager.default.trashItem(at: probe, resultingItemURL: &resulting)) != nil else {
      throw XCTSkip("no Trash available")
    }
    if let resulting { try? FileManager.default.removeItem(at: resulting as URL) }

    let outcome = FileTrash.move([file.path, directory.appendingPathComponent("missing.jpg").path])

    XCTAssertEqual(outcome.trashed, [file.path])
    XCTAssertEqual(outcome.failed.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testModesMapToThresholds() {
    XCTAssertEqual(DuplicateMode.exact.threshold, 1.0)
    XCTAssertLessThan(DuplicateMode.similar.threshold, DuplicateMode.nearIdentical.threshold)
  }
}
