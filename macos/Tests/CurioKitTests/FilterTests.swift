import XCTest

@testable import CurioKit

final class FilterTests: XCTestCase {
  /// Columns: the baseline ("a photo"), then one per active step.
  private func scores(_ rows: [String: [Float]], prompts: Int) -> PromptScores {
    let paths = rows.keys.sorted()
    return PromptScores(paths: paths, prompts: prompts, scores: paths.flatMap { rows[$0]! }, model: "m")
  }

  func testStepsRunInOrderAndRecordWhatEachRemoved() {
    // Baseline 0.20; step 1 "portrait", step 2 "blurry". Balanced needs a lead of 0.02.
    let run = FilterRun(
      steps: [FilterStep(action: .keep, text: "portrait"), FilterStep(action: .remove, text: "blurry")],
      scores: scores(
        [
          "/sharp-portrait.jpg": [0.20, 0.25, 0.19],
          "/blurry-portrait.jpg": [0.20, 0.25, 0.24],
          "/landscape.jpg": [0.20, 0.18, 0.19],
        ], prompts: 3))
    XCTAssertEqual(run.stages[0].dropped, ["/landscape.jpg"])
    XCTAssertEqual(run.stages[1].dropped, ["/blurry-portrait.jpg"])
    XCTAssertEqual(run.result, ["/sharp-portrait.jpg"])
  }

  func testStrictnessAndEmptyStepsAndMissingFiles() {
    // Leads over the baseline of 0.015 and 0.03.
    let rows: [String: [Float]] = ["/a.jpg": [0.20, 0.215], "/b.jpg": [0.20, 0.23]]
    func kept(_ strictness: FilterStep.Strictness) -> [String] {
      FilterRun(
        steps: [FilterStep(action: .keep, text: "x", strictness: strictness)],
        scores: scores(rows, prompts: 2)
      ).result
    }
    XCTAssertEqual(kept(.loose), ["/a.jpg", "/b.jpg"])
    XCTAssertEqual(kept(.balanced), ["/b.jpg"])
    XCTAssertEqual(kept(.strict), [])
    let idle = FilterRun(
      steps: [FilterStep(action: .keep, text: "  ")], scores: scores(rows, prompts: 1), among: ["/a.jpg"])
    XCTAssertEqual(idle.result, ["/a.jpg"], "a step without words changes nothing; gone files are left out")
  }

  func testExportNeverOverwrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("curio-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("in")
    let sub = source.appendingPathComponent("sub")
    let out = root.appendingPathComponent("out")
    for folder in [sub, out] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    try Data("a".utf8).write(to: source.appendingPathComponent("a.jpg"))
    try Data("b".utf8).write(to: sub.appendingPathComponent("a.jpg"))
    try Data("old".utf8).write(to: out.appendingPathComponent("a.jpg"))
    let paths = [source.appendingPathComponent("a.jpg").path, sub.appendingPathComponent("a.jpg").path]

    let copied = FileExport.run(paths, to: out, mode: .copy)
    XCTAssertEqual(copied.done.count, 2)
    XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a.jpg"), encoding: .utf8), "old")
    XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a 2.jpg"), encoding: .utf8), "a")
    XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a 3.jpg"), encoding: .utf8), "b")

    let moved = FileExport.run([paths[0]], to: out, mode: .move)
    XCTAssertEqual(moved.done, [paths[0]])
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths[0]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("a 4.jpg").path))

    let stopped = FileExport.run(paths, to: out, mode: .copy, isCancelled: { true })
    XCTAssertTrue(stopped.cancelled)
    XCTAssertEqual(stopped.done, [])
  }
}
