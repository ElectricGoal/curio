import CurioKit
import XCTest

@testable import Curio

/// A scriptable search backend, so app behaviour can be tested without a model.
final class FakeEngine: SearchEngine, @unchecked Sendable {
  private let lock = NSLock()
  private var storedStatus: Result<IndexStatus, Error> = .success(FakeEngine.notIndexed)
  private var storedModels: [ModelInfo] = [FakeEngine.model("clip-vit-b32", installed: true)]
  private var storedIndexCalls: [(model: String, rebuild: Bool, expected: Int?)] = []
  private var storedSearches: [String] = []
  private var storedDecisions: [String: Double] = [:]
  private var storedLeads: [String: Float] = [:]
  private var storedDecisionModels: [ModelInfo] = [FakeEngine.model("d1-2b", installed: true, isDefault: true)]
  /// What the stand-in model would say once asked; `decisionAnswers` holds what it has said.
  var decisionTruth: [String: Double] = [:]
  /// When set, asking waits until it is cancelled, like a long real run.
  var decidingRunsUntilCancelled = false
  private var storedDecisionRequests: [(paths: [String], questions: [String], asking: Bool)] = []
  var statusDelay: Duration?
  /// When set, an index call waits until it is cancelled, like a long real one.
  var indexRunsUntilCancelled = false

  static let notIndexed = IndexStatus(
    indexed: false, total: 1, count: 0, pending: 1, missing: 0, unreadable: 0, model: nil,
    modelName: nil, modelAvailable: nil, updatedAt: nil)

  static func indexed(model: String = "clip-vit-b32", available: Bool = true, reason: String? = nil)
    -> IndexStatus
  {
    IndexStatus(
      indexed: true, total: 1, count: 1, pending: 0, missing: 0, unreadable: 0, model: model,
      modelName: "Some Model", modelAvailable: available, updatedAt: 1, rebuildReason: reason)
  }

  static func model(_ alias: String, installed: Bool, available: Bool = true, isDefault: Bool = false)
    -> ModelInfo
  {
    ModelInfo(
      alias: alias, id: alias, name: alias.uppercased(), family: "coreml", summary: "", isDefault: isDefault,
      installed: installed, available: available,
      availabilityMessage: available ? "" : "Not included in this copy of the app.", size: 0)
  }

  var status: Result<IndexStatus, Error> {
    get { lock.withLock { storedStatus } }
    set { lock.withLock { storedStatus = newValue } }
  }
  var modelList: [ModelInfo] {
    get { lock.withLock { storedModels } }
    set { lock.withLock { storedModels = newValue } }
  }
  var indexCalls: [(model: String, rebuild: Bool, expected: Int?)] { lock.withLock { storedIndexCalls } }
  var searches: [String] { lock.withLock { storedSearches } }

  func status(folder: URL) async throws -> IndexStatus {
    if let statusDelay { try? await Task.sleep(for: statusDelay) }
    return try status.get()
  }

  /// What the stand-in decision model says for each image path; unset paths are unanswered.
  var decisionAnswers: [String: Double] {
    get { lock.withLock { storedDecisions } }
    set { lock.withLock { storedDecisions = newValue } }
  }
  var decisionRequests: [(paths: [String], questions: [String], asking: Bool)] {
    lock.withLock { storedDecisionRequests }
  }
  var decisionList: [ModelInfo] {
    get { lock.withLock { storedDecisionModels } }
    set { lock.withLock { storedDecisionModels = newValue } }
  }

  func decisions(
    folder: URL, paths: [String], questions: [String], asking: Bool,
    onProgress: @escaping ProgressHandler
  ) async throws -> DecisionScores {
    lock.withLock { storedDecisionRequests.append((paths, questions, asking)) }
    if asking {
      if decidingRunsUntilCancelled {
        // One answer lands, then the run is stopped: what it gave must be kept.
        if let first = paths.first, let truth = decisionTruth[first] { decisionAnswers[first] = truth }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        throw EngineError.cancelled
      }
      for path in paths { if let truth = decisionTruth[path] { decisionAnswers[path] = truth } }
    }
    let known = decisionAnswers
    var answers: [String: [Double?]] = [:]
    for path in paths {
      if let probability = known[path] {
        answers[path] = [Double?](repeating: probability, count: questions.count)
      }
    }
    return DecisionScores(
      model: "d1-2b", questions: questions, answers: answers,
      unanswered: paths.filter { known[$0] == nil })
  }

  func prepare(folder: URL) async throws {}

  func index(
    folder: URL, model: String, rebuild: Bool, expected: Int?,
    onProgress: @escaping ProgressHandler
  ) async throws -> IndexResponse {
    lock.withLock { storedIndexCalls.append((model, rebuild, expected)) }
    onProgress(EngineProgress(message: "Indexing images", current: 1, total: 4, unit: .images, fraction: 0.25, eta: 3, ceiling: 0.9))
    if indexRunsUntilCancelled {
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
      return IndexResponse(
        count: 1, added: 1, skipped: 0, removed: 0, remaining: 3, cancelled: true, model: model,
        modelName: "Some Model", seconds: 0.1)
    }
    status = .success(FakeEngine.indexed(model: model))
    return IndexResponse(
      count: 1, added: 1, skipped: 0, removed: 0, remaining: 0, cancelled: false, model: model,
      modelName: "Some Model", seconds: 0.1)
  }

  func search(folder: URL, text: String, limit: Int, onProgress: @escaping ProgressHandler)
    async throws -> SearchResponse
  {
    lock.withLock { storedSearches.append(text) }
    return SearchResponse(images: [], total: 0, model: "clip-vit-b32")
  }

  func search(
    folder: URL, similarTo imagePath: String, limit: Int, onProgress: @escaping ProgressHandler
  ) async throws -> SearchResponse {
    SearchResponse(images: [], total: 0, model: "clip-vit-b32")
  }

  func search(
    folder: URL, similarTo imagePath: String, adding: [String], removing: [String], limit: Int,
    onProgress: @escaping ProgressHandler
  ) async throws -> SearchResponse {
    lock.withLock { storedSearches.append((adding + removing.map { "-" + $0 }).joined(separator: ",")) }
    return SearchResponse(images: [], total: 0, model: "clip-vit-b32")
  }

  /// How well each image (absolute path) fits every step's description; unset, nothing is indexed.
  var descriptionLeads: [String: Float] {
    get { lock.withLock { storedLeads } }
    set { lock.withLock { storedLeads = newValue } }
  }

  func scores(folder: URL, prompts: [String]) async throws -> PromptScores {
    let leads = descriptionLeads
    let paths = leads.keys.sorted()
    // The first prompt is the baseline every step is compared with.
    let rows = paths.flatMap { path in
      [Float(0.2)] + [Float](repeating: 0.2 + leads[path]!, count: max(0, prompts.count - 1))
    }
    return PromptScores(paths: paths, prompts: prompts.count, scores: rows, model: "clip-vit-b32")
  }

  func duplicates(
    folder: URL, threshold: Double, exactOnly: Bool, onProgress: @escaping ProgressHandler
  ) async throws -> DuplicatesResponse {
    DuplicatesResponse(groups: [], redundant: 0, reclaimable: 0, threshold: threshold)
  }

  func models() async throws -> ModelsResponse {
    ModelsResponse(models: modelList, storage: "/models", decision: decisionList)
  }

  func downloadModel(_ alias: String, onProgress: @escaping ProgressHandler) async throws
    -> ModelChange
  {
    modelList = modelList.map { $0.alias == alias ? FakeEngine.model(alias, installed: true) : $0 }
    return ModelChange(model: alias, installed: true)
  }

  func deleteModel(_ alias: String) async throws -> ModelChange {
    ModelChange(model: alias, installed: false)
  }
}

/// How the app behaves around its engine: problems, model choices, rebuilds, pausing.
@MainActor
final class StudioEngineTests: XCTestCase {
  private var folder: URL!
  private var engine: FakeEngine!

  override func setUp() async throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("curio-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: folder.appendingPathComponent("a.jpg"))
    engine = FakeEngine()
    Studio.completionHold = .milliseconds(10)
  }

  override func tearDown() async throws {
    Studio.completionHold = .milliseconds(600)
    Studio.engineStartPatience = .seconds(5)
    try? FileManager.default.removeItem(at: folder)
  }

  private func studio(preferences: String? = nil) throws -> Studio {
    let url = folder.appendingPathComponent(".prefs.json")
    if let preferences { try Data(preferences.utf8).write(to: url) }
    return Studio(dataRoot: folder, preferencesURL: url, engine: engine)
  }

  private func wait(_ what: String, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
      guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func testADriveMacOSIsBlockingIsExplainedAndBrowsingStillWorks() async throws {
    engine.status = .failure(
      NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]))
    let studio = try studio()

    studio.open(folder)
    try await wait("the problem to be reported") { studio.engineProblem != nil }

    XCTAssertEqual(studio.engineProblem, EngineDiagnosis.permissionHint)
    XCTAssertEqual(studio.library.count, 1, "browsing still works")
    XCTAssertNil(studio.alert, "a banner explains it; no alert on every folder open")
  }

  func testAFolderWithAnIndexOffersSearchEvenBeforeTheStatusCheckAnswers() async throws {
    let index = IndexStore.location(in: folder)
    try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("index".utf8).write(to: index)
    engine.status = .failure(EngineError.failed("the status check did not answer"))
    let studio = try studio()

    studio.open(folder)
    try await wait("the status check to fail") { studio.engineProblem != nil }

    XCTAssertNil(studio.indexStatus)
    XCTAssertTrue(studio.hasIndex, "the index on disk is recognised without the engine's answer")
  }

  func testASlowStatusCheckIsAnnouncedAndThenRecovers() async throws {
    Studio.engineStartPatience = .milliseconds(100)
    engine.statusDelay = .milliseconds(700)
    let studio = try studio()

    studio.open(folder)
    try await wait("the wait to be explained") { studio.status.hasPrefix("Checking the index") }
    XCTAssertNil(studio.indexStatus)
    try await wait("the answer") { studio.indexStatus != nil }
    XCTAssertFalse(studio.status.hasPrefix("Checking the index"))
  }

  // MARK: - Appearance

  func testTheAppFollowsTheSystemUntilAnAppearanceIsChosen() throws {
    let studio = try studio()
    var applied: [Appearance] = []
    studio.applyAppearance = { applied.append($0) }
    XCTAssertEqual(studio.appearance, .system)

    studio.start()
    XCTAssertEqual(applied, [.system], "the saved choice is put in place at launch")

    studio.setAppearance(.dark)
    XCTAssertEqual(studio.appearance, .dark)
    XCTAssertEqual(applied, [.system, .dark])
    let saved = PreferencesStore(url: folder.appendingPathComponent(".prefs.json")).load().appearance
    XCTAssertEqual(saved, .dark)

    studio.setAppearance(.dark)
    XCTAssertEqual(applied.count, 2, "choosing the same again does nothing")
  }

  func testAChosenAppearanceIsRememberedAndAppliedAtLaunch() throws {
    let studio = try studio(preferences: #"{"appearance":"light"}"#)
    var applied: [Appearance] = []
    studio.applyAppearance = { applied.append($0) }
    XCTAssertEqual(studio.appearance, .light)
    studio.start()
    XCTAssertEqual(applied, [.light])
  }

  func testAnAppearanceIsPutOnTheWholeApp() async throws {
    addTeardownBlock { @MainActor in NSApplication.shared.appearance = nil }
    // A window with no appearance of its own, like the app's.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    addTeardownBlock { @MainActor in window.close() }
    func shown() -> NSAppearance.Name? { window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) }

    // Both ways, so the result cannot be the Mac's own setting showing through.
    Studio.applyToApp(.dark)
    XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
    try await wait("the window to turn dark") { shown() == .darkAqua }
    Studio.applyToApp(.light)
    XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)
    try await wait("the window to turn light") { shown() == .aqua }
    Studio.applyToApp(.system)
    XCTAssertNil(NSApplication.shared.appearance, "nothing of its own: macOS decides")
  }

  func testARememberedModelThatNoLongerExistsFallsBackAndIsSaved() async throws {
    let studio = try studio(preferences: #"{"model":"siglip-so400m"}"#)
    XCTAssertEqual(studio.selectedModel, "siglip-so400m")

    await studio.loadModels()

    XCTAssertEqual(studio.selectedModel, "clip-vit-b32")
    let saved = PreferencesStore(url: folder.appendingPathComponent(".prefs.json")).load().model
    XCTAssertEqual(saved, "clip-vit-b32")
  }

  func testAModelThisCopyCannotGetGivesWayToOneThatIsInstalled() async throws {
    // A release build that ships only one model: the default is not included.
    engine.modelList = [
      FakeEngine.model("mobileclip-s4", installed: false, available: false, isDefault: true),
      FakeEngine.model("clip-vit-b32", installed: true),
    ]
    let studio = try studio(preferences: #"{"model":"mobileclip-s4"}"#)

    await studio.loadModels()

    XCTAssertEqual(studio.selectedModel, "clip-vit-b32")
  }

  func testAChosenModelThatCanBeDownloadedIsKept() async throws {
    engine.modelList = [
      FakeEngine.model("mobileclip-s4", installed: false, available: true, isDefault: true),
      FakeEngine.model("clip-vit-b32", installed: true),
    ]
    let studio = try studio(preferences: #"{"model":"mobileclip-s4"}"#)
    await studio.loadModels()
    XCTAssertEqual(studio.selectedModel, "mobileclip-s4", "it will be downloaded when first needed")
  }

  func testAnIndexThisVersionCannotReadIsRebuiltNotSearched() async throws {
    engine.status = .success(
      FakeEngine.indexed(model: "old", available: false, reason: "Its index was made by an earlier version of the app."))
    let studio = try studio()
    studio.open(folder)
    try await wait("index status") { studio.indexStatus != nil }

    XCTAssertTrue(studio.indexNeedsRebuild)
    XCTAssertFalse(studio.indexUsesOtherModel, "not the 'switch models' hint: this one cannot be used")
    studio.query = "a beach"
    studio.submitSearch()
    XCTAssertEqual(studio.alert?.title, "This folder needs a new index")
    XCTAssertTrue(studio.alert?.message.contains("earlier version") ?? false)
    XCTAssertEqual(engine.searches, [], "the engine is not asked to search it")
    studio.alert = nil

    studio.indexFolder()  // "Update" on such a folder replaces the index
    try await wait("the rebuild") { studio.indexStatus?.needsRebuild == false && studio.activity == nil }
    XCTAssertEqual(engine.indexCalls.map(\.rebuild), [true])
    XCTAssertEqual(engine.indexCalls.first?.model, "clip-vit-b32", "with the selected model")
    XCTAssertEqual(engine.indexCalls.first?.expected, 1)
  }

  func testPausingStopsTheEngineTaskAndOffersToResume() async throws {
    engine.indexRunsUntilCancelled = true
    let studio = try studio()
    studio.open(folder)
    try await wait("index status") { studio.indexStatus != nil }

    studio.indexFolder()
    try await wait("progress to show") { (studio.activity?.fraction ?? 0) > 0 }
    XCTAssertEqual(studio.activity?.kind, .indexing)
    studio.cancelActivity()
    XCTAssertEqual(studio.activity?.isCancelling, true)

    try await wait("the pause to land") { studio.activity == nil && studio.notice != nil }
    XCTAssertEqual(studio.notice?.title, "Indexing paused")
    XCTAssertEqual(studio.notice?.offersResume, true)
  }

  func testIndexingDownloadsTheModelFirstWhenItIsNotInstalled() async throws {
    engine.modelList = [FakeEngine.model("clip-vit-b32", installed: false, available: true, isDefault: true)]
    let studio = try studio(preferences: #"{"model":"clip-vit-b32"}"#)
    studio.open(folder)
    try await wait("index status") { studio.indexStatus != nil }

    studio.indexFolder()
    try await wait("the index to finish") { studio.notice?.title == "Index ready" }

    XCTAssertTrue(studio.isInstalled("clip-vit-b32"))
    XCTAssertEqual(engine.indexCalls.count, 1)
  }

  func testIndexingWithAModelThatCannotBeObtainedExplainsWhy() async throws {
    engine.modelList = [FakeEngine.model("mobileclip-s4", installed: false, available: false, isDefault: true)]
    let studio = try studio(preferences: #"{"model":"mobileclip-s4"}"#)
    studio.open(folder)
    try await wait("index status") { studio.indexStatus != nil }

    studio.indexFolder()
    try await wait("the explanation") { studio.alert != nil }

    XCTAssertTrue(studio.alert?.message.contains("Not included") ?? false)
    XCTAssertEqual(engine.indexCalls.count, 0)
  }
}
