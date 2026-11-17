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

  // MARK: - Careful steps

  private func careful(_ action: FilterStep.Action = .keep, _ strictness: FilterStep.Strictness = .balanced)
    -> FilterStep
  {
    FilterStep(action: action, text: "portrait", strictness: strictness, careful: true)
  }

  func testACarefulStepGoesByTheDecisionModelNotTheDescription() {
    // By description, a.jpg matches and b.jpg does not; the model says the opposite.
    let step = careful()
    let rows: [String: [Float]] = ["/a.jpg": [0.20, 0.30], "/b.jpg": [0.20, 0.10]]
    let decisions = DecisionScores(
      model: "d1-2b", questions: [step.question], answers: ["/a.jpg": [0.04], "/b.jpg": [0.97]])
    let run = FilterRun(steps: [step], scores: scores(rows, prompts: 2), decisions: decisions)
    XCTAssertEqual(run.result, ["/b.jpg"])
    XCTAssertEqual(run.stages[0].unchecked, [])
  }

  func testImagesTheModelHasNotSeenFallBackToTheDescriptionAndAreCounted() {
    let step = careful()
    let rows: [String: [Float]] = ["/a.jpg": [0.20, 0.30], "/b.jpg": [0.20, 0.10], "/c.jpg": [0.20, 0.30]]
    let decisions = DecisionScores(
      model: "d1-2b", questions: [step.question], answers: ["/a.jpg": [0.04]], unanswered: ["/b.jpg"],
      unreadable: ["/c.jpg"])
    let run = FilterRun(steps: [step], scores: scores(rows, prompts: 2), decisions: decisions)
    XCTAssertEqual(run.result, ["/c.jpg"], "a.jpg by the model, b.jpg and c.jpg by description")
    XCTAssertEqual(run.stages[0].unchecked, ["/b.jpg"], "c.jpg cannot be read, so it is not waiting")
    let none = FilterRun(steps: [step], scores: scores(rows, prompts: 2))
    XCTAssertEqual(none.stages[0].unchecked.count, 3)
    XCTAssertEqual(none.result, ["/a.jpg", "/c.jpg"])
  }

  func testOnlyImagesReachingACarefulStepWaitForIt() {
    // Step 1 removes b.jpg by description, so the careful step 2 never needs to see it.
    let first = FilterStep(action: .remove, text: "blurry")
    let second = careful()
    let rows: [String: [Float]] = ["/a.jpg": [0.20, 0.10, 0.30], "/b.jpg": [0.20, 0.30, 0.30]]
    let run = FilterRun(steps: [first, second], scores: scores(rows, prompts: 3))
    XCTAssertEqual(run.stages[1].unchecked, ["/a.jpg"])
  }

  func testStrictnessSetsHowSureTheModelMustBe() {
    let rows: [String: [Float]] = ["/a.jpg": [0.20, 0.20], "/b.jpg": [0.20, 0.20], "/c.jpg": [0.20, 0.20]]
    func kept(_ strictness: FilterStep.Strictness) -> [String] {
      let step = careful(.keep, strictness)
      let decisions = DecisionScores(
        model: "d1-2b", questions: [step.question],
        answers: ["/a.jpg": [0.35], "/b.jpg": [0.6], "/c.jpg": [0.9]])
      return FilterRun(steps: [step], scores: scores(rows, prompts: 2), decisions: decisions).result
    }
    XCTAssertEqual(kept(.loose), ["/a.jpg", "/b.jpg", "/c.jpg"])
    XCTAssertEqual(kept(.balanced), ["/b.jpg", "/c.jpg"])
    XCTAssertEqual(kept(.strict), ["/c.jpg"])
  }

  func testACarefulRemoveStepTakesOutWhatTheModelIsSureOf() {
    let step = careful(.remove)
    let rows: [String: [Float]] = ["/a.jpg": [0.20, 0.20], "/b.jpg": [0.20, 0.20]]
    let decisions = DecisionScores(
      model: "d1-2b", questions: [step.question], answers: ["/a.jpg": [0.9], "/b.jpg": [0.1]])
    XCTAssertEqual(
      FilterRun(steps: [step], scores: scores(rows, prompts: 2), decisions: decisions).result, ["/b.jpg"])
  }

  func testAPlainStepIgnoresTheModelsAnswers() {
    let plain = FilterStep(action: .keep, text: "portrait")
    let rows: [String: [Float]] = ["/a.jpg": [0.20, 0.30]]
    let decisions = DecisionScores(model: "d1-2b", questions: [plain.question], answers: ["/a.jpg": [0.01]])
    let run = FilterRun(steps: [plain], scores: scores(rows, prompts: 2), decisions: decisions)
    XCTAssertEqual(run.result, ["/a.jpg"])
    XCTAssertEqual(run.stages[0].unchecked, [])
  }

  func testStepsSavedBeforeCarefulStepsExistedStillLoad() throws {
    let saved = #"[{"id":"7F0B7C1E-6B43-4E0B-9C59-2A2E4B8E6D11","action":"keep","text":"portraits","strictness":"strict"}]"#
    let steps = try JSONDecoder().decode([FilterStep].self, from: Data(saved.utf8))
    XCTAssertEqual(steps.first?.careful, false)
    XCTAssertEqual(steps.first?.strictness, .strict)
    let again = try JSONDecoder().decode(
      [FilterStep].self, from: JSONEncoder().encode([FilterStep(action: .remove, text: "x", careful: true)]))
    XCTAssertEqual(again.first?.careful, true)
  }

  func testTheQuestionQuotesTheDescriptionWithoutStraySpaces() {
    XCTAssertEqual(
      FilterStep(action: .keep, text: "  screenshots ").question,
      "Does this image match the description “screenshots”?")
  }

  func testTheTraceSaysWhatEachStepDecidedAndWhy() {
    // #1 keeps "portrait" by description; #2 removes "blurry" by the model.
    let first = FilterStep(number: 1, action: .keep, text: "portrait")
    let second = FilterStep(number: 2, action: .remove, text: "blurry", model: "d1-2b")
    let rows: [String: [Float]] = [
      "/sharp.jpg": [0.20, 0.25, 0.10], "/soft.jpg": [0.20, 0.25, 0.10], "/view.jpg": [0.20, 0.18, 0.10],
    ]
    let decisions = DecisionScores(
      model: "d1-2b", questions: [second.question], answers: ["/sharp.jpg": [0.1], "/soft.jpg": [0.9]])
    let run = FilterRun(steps: [first, second], scores: scores(rows, prompts: 3), answers: ["d1-2b": decisions])

    let soft = run.trace(of: "/soft.jpg")
    XCTAssertEqual(soft.map(\.step), [first.id, second.id])
    XCTAssertEqual(soft.map(\.kept), [true, false], "kept by #1, removed by #2")
    guard case .description(let lead, let needed) = soft[0].evidence else { return XCTFail("#1 goes by description") }
    XCTAssertEqual(lead, 0.05, accuracy: 0.0001)
    XCTAssertEqual(needed, 0.02, accuracy: 0.0001)
    XCTAssertEqual(soft[1].evidence, .model(alias: "d1-2b", yes: 0.9, needed: 0.5))

    let view = run.trace(of: "/view.jpg")
    XCTAssertEqual(view.count, 1, "removed by #1, so #2 never saw it")
    XCTAssertFalse(view[0].kept)
    XCTAssertEqual(run.trace(of: "/sharp.jpg").map(\.kept), [true, true])
    XCTAssertEqual(run.result, ["/sharp.jpg"])
  }

  func testEachModelStepReadsOnlyItsOwnModelsAnswers() {
    let big = FilterStep(action: .keep, text: "portrait", model: "d1-2b")
    let small = FilterStep(action: .keep, text: "portrait", model: "d1-2b-4bit")
    let rows: [String: [Float]] = ["/a.jpg": [0.20, 0.20, 0.20]]
    let answers = [
      "d1-2b": DecisionScores(model: "d1-2b", questions: [big.question], answers: ["/a.jpg": [0.9]]),
      "d1-2b-4bit": DecisionScores(model: "d1-2b-4bit", questions: [small.question], answers: ["/a.jpg": [0.1]]),
    ]
    let run = FilterRun(steps: [big, small], scores: scores(rows, prompts: 3), answers: answers)
    XCTAssertEqual(run.trace(of: "/a.jpg").map(\.kept), [true, false])
    XCTAssertEqual(run.trace(of: "/a.jpg")[1].evidence, .model(alias: "d1-2b-4bit", yes: 0.1, needed: 0.5))
  }

  func testImagesAModelHasNotSeenAreTracedAsJudgedByDescription() {
    let step = FilterStep(action: .keep, text: "portrait", model: "d1-2b")
    let run = FilterRun(steps: [step], scores: scores(["/a.jpg": [0.20, 0.25]], prompts: 2))
    guard case .notLookedAt(let alias, let unreadable, _, _) = run.trace(of: "/a.jpg")[0].evidence else {
      return XCTFail("not looked at yet")
    }
    XCTAssertEqual(alias, "d1-2b")
    XCTAssertFalse(unreadable)
  }

  func testStepNumbersAreGivenOnceAndKeptThroughSaving() throws {
    let numbered = FilterStep.numbered([
      FilterStep(number: 4, action: .keep, text: "a"), FilterStep(action: .keep, text: "b"),
      FilterStep(action: .remove, text: "c"),
    ])
    XCTAssertEqual(numbered.map(\.number), [4, 5, 6], "new numbers follow the highest, in chain order")
    let saved = try JSONDecoder().decode(FilterStep.self, from: JSONEncoder().encode(numbered[1]))
    XCTAssertEqual(saved, numbered[1])
  }

  func testAStepSavedAsCarefulUsesTheDefaultModel() throws {
    let json = #"{"id":"11111111-1111-1111-1111-111111111111","action":"keep","text":"x","strictness":"balanced","careful":true}"#
    let step = try JSONDecoder().decode(FilterStep.self, from: Data(json.utf8))
    XCTAssertEqual(step.model, FilterStep.defaultModel, "it follows the model chosen in Settings")
    XCTAssertEqual(step.number, 0, "numbered when the app loads the chain")
    var plain = step
    plain.careful = false
    XCTAssertNil(plain.model)
  }
}
