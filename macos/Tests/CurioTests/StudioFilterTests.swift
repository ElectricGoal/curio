import CurioKit
import XCTest

@testable import Curio

/// Careful filter steps, where a second model looks at each image: what the
/// Filter page shows before, while and after it has looked.
@MainActor
final class StudioFilterTests: XCTestCase {
  private var folder: URL!
  private var engine: FakeEngine!
  private var portrait: String { folder.appendingPathComponent("portrait.jpg").path }
  private var logo: String { folder.appendingPathComponent("logo.jpg").path }
  private var mannequin: String { folder.appendingPathComponent("mannequin.jpg").path }

  override func setUp() async throws {
    // Resolved up front: the library lists files by their real path.
    folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("curio-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["portrait.jpg", "logo.jpg", "mannequin.jpg"] {
      try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }
    engine = FakeEngine()
    engine.status = .success(FakeEngine.indexed())
    // By description all three look like "photos of people"; only one is.
    engine.descriptionLeads = [portrait: 0.05, logo: 0.05, mannequin: 0.05]
    engine.decisionTruth = [portrait: 0.97, logo: 0.03, mannequin: 0.4]
    Studio.completionHold = .milliseconds(10)
  }

  override func tearDown() async throws {
    Studio.completionHold = .milliseconds(600)
    try? FileManager.default.removeItem(at: folder)
  }

  private func wait(_ what: String, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
      guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// A studio on the folder with one keep step for "photos of people".
  private func studio(careful: Bool) async throws -> Studio {
    let studio = Studio(
      dataRoot: folder, preferencesURL: folder.appendingPathComponent(".prefs.json"), engine: engine)
    studio.open(folder)
    try await wait("the folder to be read") { studio.library.count == 3 && studio.indexStatus != nil }
    await studio.loadModels()
    studio.addStep(.keep, text: "photos of people")
    if careful { studio.updateStep(studio.filterSteps[0].id) { $0.careful = true } }
    studio.runFilter(immediately: true)
    try await wait("the chain to run") { studio.filterRun != nil && !studio.isFiltering }
    return studio
  }

  private func names(_ paths: [String]?) -> [String] {
    (paths ?? []).map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
  }

  func testAPlainStepNeverTroublesTheDecisionModel() async throws {
    let studio = try await studio(careful: false)
    XCTAssertEqual(names(studio.filterRun?.result), ["logo.jpg", "mannequin.jpg", "portrait.jpg"])
    XCTAssertEqual(studio.uncheckedCount(at: 0), 0)
    XCTAssertTrue(engine.decisionRequests.isEmpty)
  }

  func testACarefulStepShowsWhatIsWaitingWithoutStartingTheSlowWork() async throws {
    let studio = try await studio(careful: true)
    XCTAssertEqual(studio.uncheckedCount(at: 0), 3)
    XCTAssertEqual(
      names(studio.filterRun?.result), ["logo.jpg", "mannequin.jpg", "portrait.jpg"],
      "matched by description until the model has looked")
    XCTAssertFalse(engine.decisionRequests.contains { $0.asking }, "looking is the user's call")
    XCTAssertNil(studio.activity)
  }

  func testLookNowAsksAboutTheWaitingImagesAndTheChainUsesTheAnswers() async throws {
    let studio = try await studio(careful: true)
    let step = studio.filterSteps[0]

    studio.lookAtImages(for: step.id)
    try await wait("the model to finish") { studio.uncheckedCount(at: 0) == 0 && studio.activity == nil }

    let asked = try XCTUnwrap(engine.decisionRequests.first { $0.asking })
    XCTAssertEqual(names(asked.paths), ["logo.jpg", "mannequin.jpg", "portrait.jpg"])
    XCTAssertEqual(asked.questions, [step.question])
    XCTAssertEqual(names(studio.filterRun?.result), ["portrait.jpg"])
    XCTAssertTrue(studio.status.hasPrefix("Looked at 3"), studio.status)
  }

  func testStoppingPartWayKeepsWhatWasAnswered() async throws {
    engine.decidingRunsUntilCancelled = true
    let studio = try await studio(careful: true)

    studio.lookAtImages(for: studio.filterSteps[0].id)
    try await wait("the run to start") { studio.activity?.kind == .deciding }
    XCTAssertTrue(studio.activity?.kind.canCancel ?? false)
    studio.cancelActivity()
    try await wait("the run to stop") { studio.activity == nil && !studio.isFiltering }
    try await wait("the chain to catch up") { studio.uncheckedCount(at: 0) == 2 }

    XCTAssertNil(studio.alert, "stopping is not a failure")
    XCTAssertEqual(studio.status, "Cancelled")
  }

  func testWithoutTheModelLookNowExplainsWhereToGetIt() async throws {
    engine.decisionList = [FakeEngine.model("d1-2b", installed: false, isDefault: true)]
    let studio = try await studio(careful: true)

    studio.lookAtImages(for: studio.filterSteps[0].id)
    try await wait("the explanation") { studio.alert != nil }

    XCTAssertTrue(studio.alert?.message.contains("Settings") ?? false)
    XCTAssertFalse(engine.decisionRequests.contains { $0.asking })
  }

  // MARK: - Choosing between decision models

  private var bothModels: [ModelInfo] {
    [
      FakeEngine.model("d1-2b", installed: true, isDefault: true),
      FakeEngine.model("d1-2b-4bit", installed: true),
    ]
  }

  func testCarefulStepsAskTheSelectedModelAndTheChoiceIsRemembered() async throws {
    engine.decisionList = bothModels
    let studio = try await studio(careful: true)
    XCTAssertEqual(studio.decisionModel?.alias, "d1-2b", "the default until another is chosen")

    studio.selectDecisionModel("d1-2b-4bit")
    try await wait("the chain to be read again") {
      !studio.isFiltering && engine.decisionModelsAsked.last == "d1-2b-4bit"
    }
    studio.lookAtImages(for: studio.filterSteps[0].id)
    try await wait("the model to look") { engine.decisionRequests.contains { $0.asking } }
    try await wait("the run to end") { studio.activity == nil && !studio.isFiltering }

    let asking = zip(engine.decisionRequests, engine.decisionModelsAsked).filter { $0.0.asking }
    XCTAssertEqual(asking.map(\.1), ["d1-2b-4bit"])
    XCTAssertEqual(studio.decisionModel?.alias, "d1-2b-4bit")
    let saved = PreferencesStore(url: folder.appendingPathComponent(".prefs.json")).load()
    XCTAssertEqual(saved.decisionModel, "d1-2b-4bit")
  }

  func testTheOnlyInstalledModelIsTheOneUsed() async throws {
    engine.decisionList = [
      FakeEngine.model("d1-2b", installed: false, isDefault: true),
      FakeEngine.model("d1-2b-4bit", installed: true),
    ]
    let studio = try await studio(careful: true)

    XCTAssertEqual(studio.decisionModel?.alias, "d1-2b-4bit")
    studio.lookAtImages(for: studio.filterSteps[0].id)
    try await wait("the model to look") { engine.decisionRequests.contains { $0.asking } }
    try await wait("the run to end") { studio.activity == nil && !studio.isFiltering }
    XCTAssertNil(studio.alert)
    XCTAssertEqual(engine.decisionModelsAsked.last, "d1-2b-4bit")
  }

  func testAChosenModelThatIsInstalledIsKeptWhenAnotherArrives() async throws {
    try JSONEncoder().encode(Preferences(decisionModel: "d1-2b-4bit"))
      .write(to: folder.appendingPathComponent(".prefs.json"))
    engine.decisionList = bothModels
    let studio = try await studio(careful: false)

    XCTAssertEqual(studio.decisionModel?.alias, "d1-2b-4bit")
  }

  func testRemovingTheSelectedModelMovesCarefulStepsToTheOneLeftAndSaysSo() async throws {
    engine.decisionList = bothModels
    let studio = try await studio(careful: true)
    XCTAssertEqual(studio.decisionModel?.alias, "d1-2b")

    engine.decisionList = [
      FakeEngine.model("d1-2b", installed: false, isDefault: true),
      FakeEngine.model("d1-2b-4bit", installed: true),
    ]
    await studio.loadModels()

    XCTAssertEqual(studio.decisionModel?.alias, "d1-2b-4bit")
    XCTAssertTrue(studio.status.contains("D1-2B-4BIT"), studio.status)
    try await wait("the chain to be read with the other model") {
      !studio.isFiltering && engine.decisionModelsAsked.last == "d1-2b-4bit"
    }
  }

  func testAModelTheAppNoLongerKnowsGivesWayToTheDefault() async throws {
    try JSONEncoder().encode(Preferences(decisionModel: "gone"))
      .write(to: folder.appendingPathComponent(".prefs.json"))
    engine.decisionList = [
      FakeEngine.model("d1-2b", installed: false, isDefault: true),
      FakeEngine.model("d1-2b-4bit", installed: false),
    ]
    let studio = try await studio(careful: false)

    XCTAssertEqual(studio.selectedDecisionModel, "d1-2b")
  }

  func testTheChoiceIsSavedWithTheStepAndStrictnessDoesNotChangeWhoIsWaiting() async throws {
    let studio = try await studio(careful: true)
    studio.updateStep(studio.filterSteps[0].id) { $0.strictness = .strict }
    // The chain re-runs shortly after an edit; wait for that run, not the one before it.
    try await Task.sleep(for: .milliseconds(500))
    try await wait("the chain to settle") { !studio.isFiltering && studio.filterRun != nil }

    XCTAssertEqual(studio.uncheckedCount(at: 0), 3, "strictness changes the verdict, not who is waiting")
    let saved = PreferencesStore(url: folder.appendingPathComponent(".prefs.json")).load().filterSteps
    XCTAssertEqual(saved.first?.careful, true)
    XCTAssertEqual(saved.first?.strictness, .strict)
  }
}
