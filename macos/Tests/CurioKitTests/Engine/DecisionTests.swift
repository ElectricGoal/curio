import XCTest

@testable import CurioKit

/// Answers by file name, and a record of what was asked: a decision model
/// without the gigabytes.
final class NameModel: DecisionModel, @unchecked Sendable {
  let alias = "d1-2b"
  let asked = Locked<[(image: String, questions: [String])]>([])
  /// Called before each answer; tests use it to cancel or fail part-way.
  var beforeAnswer: (@Sendable (String) async throws -> Void)?

  func decide(image: URL, questions: [String]) async throws -> [Double] {
    try await beforeAnswer?(image.lastPathComponent)
    if image.lastPathComponent.hasPrefix("broken") {
      throw ImagePreprocessor.Failure.undecodable(image.lastPathComponent)
    }
    asked.update { $0.append((image.lastPathComponent, questions)) }
    // "Is it red?" is yes for files named red…, and so on.
    return questions.map { question in
      image.lastPathComponent.hasPrefix(question) ? 0.95 : 0.05
    }
  }
}

/// Counts how many of itself exist, to show that models are not held two at a time.
final class CountedModel: DecisionModel, @unchecked Sendable {
  let alias: String
  private let alive: Locked<Int>

  init(alias: String, alive: Locked<Int>) {
    self.alias = alias
    self.alive = alive
    alive.update { $0 += 1 }
  }

  deinit { alive.update { $0 -= 1 } }

  func decide(image: URL, questions: [String]) async throws -> [Double] {
    questions.map { _ in 0.5 }
  }
}

final class DecisionEngineTests: XCTestCase {
  private var root: URL!
  private var photos: URL!
  private var model: NameModel!
  private var loads: Locked<Int>!
  private var engine: NativeEngine!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("curio-" + UUID().uuidString)
    photos = root.appendingPathComponent("photos")
    try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
    model = NameModel()
    loads = Locked(0)
    let model = model!
    let loads = loads!
    engine = NativeEngine(
      dataRoot: root.appendingPathComponent("data"),
      decisionLoader: { _ in
        loads.update { $0 += 1 }
        return model
      })
    for name in ["red-1.png", "red-2.png", "green-1.png"] { try write(name) }
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func write(_ name: String, modified: Date? = nil) throws {
    let url = photos.appendingPathComponent(name)
    try Data(name.utf8).write(to: url)
    if let modified {
      try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
  }

  private var paths: [String] {
    ["red-1.png", "red-2.png", "green-1.png"].map { photos.appendingPathComponent($0).path }
  }

  private func decide(
    _ questions: [String], paths: [String]? = nil, asking: Bool = true, model: String = "d1-2b",
    onProgress: @escaping ProgressHandler = { _ in }
  ) async throws -> DecisionScores {
    try await engine.decisions(
      folder: photos, model: model, paths: paths ?? self.paths, questions: questions,
      asking: asking, onProgress: onProgress)
  }

  func testEachModelKeepsItsOwnAnswers() async throws {
    _ = try await decide(["red"])
    let asked = model.asked.update { $0 }.count
    // The other model has not looked at anything yet, whatever the first said.
    let other = try await decide(["red"], asking: false, model: "d1-2b-4bit")
    XCTAssertEqual(other.model, "d1-2b-4bit")
    XCTAssertTrue(other.answers.isEmpty)
    XCTAssertEqual(Set(other.unanswered), Set(paths))
    let answered = try await decide(["red"], model: "d1-2b-4bit")
    XCTAssertEqual(answered.answers.count, paths.count)
    XCTAssertEqual(model.asked.update { $0 }.count, asked + paths.count, "every image is asked again")
    XCTAssertEqual(loads.update { $0 }, 2, "one load per model")
    // And the first model's answers are still there.
    let first = try await decide(["red"], asking: false)
    XCTAssertTrue(first.unanswered.isEmpty)
  }

  func testEveryImageIsAnsweredForEveryQuestion() async throws {
    let scores = try await decide(["red", "green"])
    XCTAssertEqual(scores.questions, ["red", "green"])
    XCTAssertEqual(scores.answers[paths[0]], [0.95, 0.05])
    XCTAssertEqual(scores.answers[paths[2]], [0.05, 0.95])
    XCTAssertEqual(scores.unanswered, [])
    XCTAssertEqual(model.asked.update { $0.count }, 3, "one look per image, all its questions together")
  }

  func testAnswersAreRememberedAndOnlyNewQuestionsAreAsked() async throws {
    _ = try await decide(["red"])
    model.asked.update { $0 = [] }

    let again = try await decide(["red", "green"])

    XCTAssertEqual(again.answers[paths[0]], [0.95, 0.05])
    let asked = model.asked.update { $0 }
    XCTAssertEqual(asked.count, 3)
    XCTAssertTrue(asked.allSatisfy { $0.questions == ["green"] }, "red was already known")
    XCTAssertEqual(loads.update { $0 }, 1, "the model is loaded once")
  }

  func testAnswersSurviveANewEngine() async throws {
    _ = try await decide(["red"])
    let fresh = NativeEngine(
      dataRoot: root.appendingPathComponent("data"),
      decisionLoader: { _ in throw EngineError.failed("the model must not be needed") })

    let scores = try await fresh.decisions(
      folder: photos, model: "d1-2b", paths: paths, questions: ["red"], asking: true,
      onProgress: { _ in })

    XCTAssertEqual(scores.answers[paths[1]], [0.95])
  }

  func testLookingWithoutAskingReportsWhatIsMissingAndWritesNothing() async throws {
    let before = try await decide(["red"], asking: false)
    XCTAssertEqual(before.answers, [:])
    XCTAssertEqual(Set(before.unanswered), Set(paths))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: DecisionStore.location(in: photos).path),
      "only looking must not leave a file in the user's folder")
    XCTAssertEqual(loads.update { $0 }, 0, "and must not load the model")

    _ = try await decide(["red"], paths: [paths[0]])
    let after = try await decide(["red"], asking: false)
    XCTAssertEqual(after.answers, [paths[0]: [0.95]])
    XCTAssertEqual(Set(after.unanswered), Set(paths.dropFirst()))
  }

  func testAChangedFileIsAskedAgain() async throws {
    _ = try await decide(["red"])
    model.asked.update { $0 = [] }
    try write("red-1.png", modified: Date().addingTimeInterval(120))

    _ = try await decide(["red"])

    XCTAssertEqual(model.asked.update { $0.map(\.image) }, ["red-1.png"])
  }

  func testAFileThatIsNotAPictureIsRememberedAndNotAskedAgain() async throws {
    try write("broken.png")
    let broken = photos.appendingPathComponent("broken.png").path

    let first = try await decide(["red"], paths: paths + [broken])
    XCTAssertEqual(first.unreadable, [broken])
    XCTAssertNil(first.answers[broken])
    XCTAssertEqual(first.unanswered, [])

    let tried = Locked(0)
    model.beforeAnswer = { name in if name == "broken.png" { tried.update { $0 += 1 } } }
    let second = try await decide(["red", "green"], paths: [broken])
    XCTAssertEqual(second.unreadable, [broken])
    XCTAssertEqual(tried.update { $0 }, 0, "even for a question it was never asked")
  }

  func testStoppingPartWayKeepsTheAnswersSoFar() async throws {
    let seen = Locked(0)
    model.beforeAnswer = { _ in
      if seen.update({ count in count += 1; return count }) == 3 { throw EngineError.cancelled }
    }
    do {
      _ = try await decide(["red"])
      XCTFail("should have stopped")
    } catch { XCTAssertEqual(error as? EngineError, .cancelled) }

    model.beforeAnswer = nil
    let kept = try await decide(["red"], asking: false)
    XCTAssertEqual(kept.answers.count, 2)
    XCTAssertEqual(kept.unanswered.count, 1)
  }

  func testAFaultThatIsNotAboutOnePictureStopsTheRunAndKeepsEarlierAnswers() async throws {
    let seen = Locked(0)
    model.beforeAnswer = { _ in
      if seen.update({ count in count += 1; return count }) == 2 {
        throw EngineError.failed("The decision model stopped: out of memory")
      }
    }
    do {
      _ = try await decide(["red"])
      XCTFail("a failing GPU must not be mistaken for an unreadable picture")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("out of memory"), error.localizedDescription)
    }
    model.beforeAnswer = nil
    let kept = try await decide(["red"], asking: false)
    XCTAssertEqual(kept.answers.count, 1)
    XCTAssertEqual(kept.unreadable, [], "nothing was written off as unreadable")
    XCTAssertEqual(kept.unanswered.count, 2)
  }

  func testAnswersFromBeforeTheWordingOrPictureSizeChangedAreNotReused() async throws {
    // What an older version of the app would have left behind, under its own key.
    let store = try DecisionStore(folder: photos)
    let modified = try XCTUnwrap(
      try URL(fileURLWithPath: paths[0]).resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate?.timeIntervalSince1970)
    try store.save(
      model: "d1-2b/0", path: "red-1.png", modified: modified, questions: ["red"], probabilities: [0.01])
    store.close()

    let scores = try await decide(["red"], paths: [paths[0]])

    XCTAssertEqual(scores.answers[paths[0]], [0.95], "asked afresh")
    XCTAssertNotEqual(NativeEngine.answersKey(for: "d1-2b"), "d1-2b/0")
  }

  func testProgressCountsImagesAndEndsFull() async throws {
    let reports = Locked<[EngineProgress]>([])
    _ = try await decide(["red"], onProgress: { progress in reports.update { $0.append(progress) } })
    let all = reports.update { $0 }
    XCTAssertEqual(all.last?.fraction, 1)
    XCTAssertEqual(all.last?.total, 3)
    let fractions = all.compactMap(\.fraction)
    XCTAssertEqual(fractions, fractions.sorted())
  }

  func testTheModelCannotBeRemovedWhileItIsAnswering() async throws {
    let engine = engine!
    let attempt = Locked<Error?>(nil)
    model.beforeAnswer = { _ in
      do { _ = try await engine.deleteModel("d1-2b") } catch { attempt.update { $0 = error } }
    }
    _ = try await decide(["red"], paths: [paths[0]])
    guard case .busy = attempt.update({ $0 }) as? EngineError else {
      return XCTFail("expected the removal to be refused, got \(String(describing: attempt.update { $0 }))")
    }
  }

  func testSwitchingModelsLetsGoOfTheFirstBeforeReadingTheSecond() async throws {
    let alive = Locked(0)
    let most = Locked(0)
    let switching = NativeEngine(
      dataRoot: root.appendingPathComponent("switching"),
      decisionLoader: { alias in
        // What is in memory while this one is being read: nothing else may be.
        let others = alive.update { $0 }
        most.update { $0 = max($0, others + 1) }
        return CountedModel(alias: alias, alive: alive)
      })
    for alias in ["d1-2b", "d1-2b-4bit", "d1-2b"] {
      let scores = try await switching.decisions(
        folder: photos, model: alias, paths: paths, questions: ["red"], asking: true,
        onProgress: { _ in })
      XCTAssertEqual(scores.model, alias)
    }
    XCTAssertEqual(most.update { $0 }, 1, "two models were in memory at once")
  }

  func testAnotherModelIsRefusedWhileOneIsAnswering() async throws {
    let engine = engine!
    let photos = photos!
    let other = [paths[1]]
    let attempt = Locked<Error?>(nil)
    model.beforeAnswer = { _ in
      do {
        _ = try await engine.decisions(
          folder: photos, model: "d1-2b-4bit", paths: other, questions: ["red"], asking: true,
          onProgress: { _ in })
      } catch { attempt.update { $0 = error } }
    }
    let scores = try await decide(["red"], paths: [paths[0]])
    XCTAssertEqual(scores.answers[paths[0]], [0.95], "the run in progress is not disturbed")
    guard case .busy = attempt.update({ $0 }) as? EngineError else {
      return XCTFail("expected the second model to be refused, got \(String(describing: attempt.update { $0 }))")
    }
    XCTAssertEqual(loads.update { $0 }, 1)
    // Once the first has finished, the other may take its place.
    model.beforeAnswer = nil
    let later = try await decide(["red"], paths: other, model: "d1-2b-4bit")
    XCTAssertEqual(later.answers[other[0]], [0.95])
  }

  func testAModelCannotBeRemovedWhileItIsBeingRead() async throws {
    let attempt = Locked<Error?>(nil)
    let slow = Locked<NativeEngine?>(nil)
    let loading = NativeEngine(
      dataRoot: root.appendingPathComponent("loading"),
      decisionLoader: { alias in
        do { _ = try await slow.update { $0 }?.deleteModel(alias) } catch { attempt.update { $0 = error } }
        return NameModel()
      })
    slow.update { $0 = loading }
    _ = try await loading.decisions(
      folder: photos, model: "d1-2b-4bit", paths: [paths[0]], questions: ["red"], asking: true,
      onProgress: { _ in })
    guard case .busy = attempt.update({ $0 }) as? EngineError else {
      return XCTFail("expected the removal to be refused, got \(String(describing: attempt.update { $0 }))")
    }
  }

  func testWithoutTheModelInstalledTheErrorSaysWhereToGetIt() async throws {
    let plain = NativeEngine(dataRoot: root.appendingPathComponent("empty"))
    do {
      _ = try await plain.decisions(
        folder: photos, model: "d1-2b", paths: paths, questions: ["red"], asking: true,
        onProgress: { _ in })
      XCTFail("should have failed")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Settings"), error.localizedDescription)
    }
  }

  func testTheModelListNamesTheDecisionModelSeparately() async throws {
    let response = try await engine.models()
    XCTAssertEqual(response.decision.map(\.alias), ["d1-2b", "d1-2b-4bit"])
    XCTAssertEqual(response.decision.filter(\.isDefault).map(\.alias), ["d1-2b"])
    XCTAssertFalse(response.models.contains { $0.alias == "d1-2b" }, "a folder is never indexed with it")
    XCTAssertEqual(response.decision.first?.installed, false)
  }
}

final class DecisionLibraryTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("curio-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  static let settings = """
    {"model_type": "lfm3_vl", "d1_attention": "set", "d1_vision_max_pixels": 1638400,
     "projector_layer_norm_eps": 1e-06,
     "text_config": {"hidden_size": 8, "num_attention_heads": 2, "num_key_value_heads": 1, "head_dim": 4,
       "layer_types": ["conv", "full_attention"], "norm_eps": 1e-05, "conv_L_cache": 3,
       "sliding_window": 4, "use_sandwich_norm": true,
       "rope_parameters": {"full_attention": {"rope_theta": 1000000.0, "partial_rotary_factor": 0.5}}},
     "vision_config": {"hidden_size": 8, "num_attention_heads": 2, "num_key_value_heads": 1,
       "layer_types": ["conv"], "norm_eps": 1e-05, "patch_size": 16, "temporal_patch_size": 2,
       "spatial_merge_size": 2, "in_channels": 3, "conv_kernel_size": 3,
       "rope_parameters": {"rope_theta": 1000000.0, "rope_type": "axial"}}}
    """

  /// A tiny stand-in for the published model, served from a folder.
  private func library(settings: String = DecisionLibraryTests.settings, damaged: Bool = false) throws
    -> DecisionLibrary
  {
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let contents: [(String, Data)] = [
      ("config.json", Data(settings.utf8)), ("tokenizer.json", Data("{}".utf8)),
      ("model.safetensors", Data(repeating: 3, count: 40_000)),
    ]
    var files: [ModelLibrary.RemoteFile] = []
    for (name, data) in contents {
      let url = source.appendingPathComponent(name)
      try data.write(to: url)
      files.append(
        .init(
          path: name, size: Int64(data.count),
          sha256: damaged && name == "model.safetensors"
            ? String(repeating: "0", count: 64) : try ModelLibrary.sha256(of: url)))
    }
    let entry = DecisionCatalog.Entry(
      alias: "tiny", name: "Tiny", summary: "", source: source, files: files)
    return DecisionLibrary(installDirectory: root.appendingPathComponent("installed"), catalog: [entry])
  }

  func testEveryPublishedModelIsPinnedToOneRevisionWithChecksums() throws {
    XCTAssertNotNil(DecisionCatalog.entry(DecisionCatalog.defaultAlias))
    XCTAssertEqual(Set(DecisionCatalog.entries.map(\.alias)).count, DecisionCatalog.entries.count)
    for entry in DecisionCatalog.entries {
      XCTAssertTrue(entry.source.absoluteString.hasPrefix("https://huggingface.co/LiquidAI/"), entry.alias)
      XCTAssertNotNil(
        entry.source.absoluteString.range(of: #"/resolve/[0-9a-f]{40}$"#, options: .regularExpression),
        "\(entry.alias): a branch name could change under the app; a commit cannot")
      XCTAssertTrue(entry.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 }, entry.alias)
      XCTAssertTrue(
        Set(DecisionLibrary.requiredFiles).isSubset(of: Set(entry.files.map(\.path))), entry.alias)
      XCTAssertTrue(
        entry.files.contains { $0.path == "LICENSE" }, "\(entry.alias): the licence travels with the model")
    }
  }

  /// Two builds of one model differ only in how they are packed, so each says which it is.
  func testEveryPublishedModelNamesItsQuantization() throws {
    for entry in DecisionCatalog.entries {
      let address = entry.source.absoluteString
      let match = try XCTUnwrap(
        address.range(of: #"MLX-\d+bit"#, options: .regularExpression), entry.alias)
      let bits = address[match].filter(\.isNumber)
      XCTAssertTrue(entry.name.hasSuffix("(\(bits)-bit)"), "\(entry.alias): \(entry.name)")
      XCTAssertTrue(entry.summary.contains("quantized to \(bits) bits"), entry.alias)
      XCTAssertTrue(entry.summary.contains("MLX"), entry.alias)
    }
  }

  /// The real thing, from Liquid AI's repository: gigabytes, so only on request
  /// (`CURIO_D1_DOWNLOAD=1` for the default model, or a model's alias). Proves
  /// the pinned address and checksums are right.
  func testAPublishedModelDownloadsAndPassesItsChecksums() async throws {
    let asked = ProcessInfo.processInfo.environment["CURIO_D1_DOWNLOAD"] ?? ""
    let alias = asked == "1" ? DecisionCatalog.defaultAlias : asked
    try XCTSkipUnless(
      DecisionCatalog.entry(alias) != nil,
      "set CURIO_D1_DOWNLOAD=1, or to a model's alias, to download the real model (gigabytes)")
    let library = DecisionLibrary(installDirectory: root.appendingPathComponent("installed"))
    let last = Locked<[Int64]>([0, 0])

    try await library.install(alias) { done, total in last.update { $0 = [done, total] } }

    let directory = try XCTUnwrap(library.directory(for: alias))
    XCTAssertEqual(last.update { $0 }[0], DecisionCatalog.entry(alias)?.downloadSize)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("LICENSE").path))
    XCTAssertNoThrow(try D1Config.load(from: directory))
  }

  func testDownloadVerifiesInstallsAndCanBeRemoved() async throws {
    let library = try library()
    XCTAssertEqual(library.models().first?.installed, false)

    try await library.install("tiny") { _, _ in }

    XCTAssertNotNil(library.directory(for: "tiny"))
    XCTAssertEqual(library.models().first?.installed, true)
    XCTAssertGreaterThan(library.models().first?.size ?? 0, 40_000)
    try library.remove("tiny")
    XCTAssertNil(library.directory(for: "tiny"))
  }

  func testADamagedDownloadInstallsNothing() async throws {
    let library = try library(damaged: true)
    do {
      try await library.install("tiny") { _, _ in }
      XCTFail("should have been rejected")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("damaged"), error.localizedDescription)
    }
    XCTAssertNil(library.directory(for: "tiny"))
    XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: library.installDirectory.path), [])
  }

  func testAModelOfAKindTheAppCannotRunIsNotInstalled() async throws {
    let other = DecisionLibraryTests.settings.replacingOccurrences(of: "\"set\"", with: "\"causal\"")
    let library = try library(settings: other)
    do {
      try await library.install("tiny") { _, _ in }
      XCTFail("should have been rejected")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("cannot run"), error.localizedDescription)
    }
    XCTAssertNil(library.directory(for: "tiny"))
  }

  func testAFolderMissingTheWeightsIsNotAnInstalledModel() throws {
    let library = try library()
    let partial = library.installDirectory.appendingPathComponent("tiny")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: partial.appendingPathComponent("config.json"))
    XCTAssertNil(library.directory(for: "tiny"))
    XCTAssertEqual(library.models().first?.installed, false)
  }
}
