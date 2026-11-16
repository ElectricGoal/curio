import AppKit
import CurioKit
import SwiftUI
import XCTest

@testable import Curio

/// Drives the app's real state object against the real engine and a real
/// model, and renders the window offscreen after each step.
///
/// Opt in with `CURIO_E2E=1` (it loads a model). Needs converted models: run
/// `scripts/convert-models.sh` first.
/// Snapshots land in `CURIO_SNAPSHOT_DIR`, or a temporary folder that is printed.
@MainActor
final class EndToEndTests: XCTestCase {
  /// The app's default model; `CURIO_E2E_MODEL=clip-vit-b32` runs the lighter one.
  private static let model = ProcessInfo.processInfo.environment["CURIO_E2E_MODEL"] ?? "mobileclip-s4"
  private static let samples = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails")

  private var workspace: URL!
  private var snapshots: URL!
  private var window: NSWindow!

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["CURIO_E2E"] == "1", "set CURIO_E2E=1 to run the end-to-end test")
    workspace = FileManager.default.temporaryDirectory.appendingPathComponent("curio-e2e-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    snapshots = environment["CURIO_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:)) ?? workspace.appendingPathComponent("snapshots")
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    window?.close()
    if let workspace { try? FileManager.default.removeItem(at: workspace.appendingPathComponent("photos")) }
  }

  func testBrowseIndexSearchAndReviewDuplicates() async throws {
    let root = try projectRoot()
    let folder = try makePhotoFolder()
    let studio = Studio(dataRoot: root, preferencesURL: workspace.appendingPathComponent("preferences.json"))
    show(studio)
    studio.selectModel(Self.model)

    // Browse: the folder's images appear before any indexing.
    studio.open(folder)
    try await wait("library scan") { !studio.isScanning && studio.indexStatus != nil }
    XCTAssertEqual(studio.library.count, 43)
    XCTAssertEqual(studio.indexStatus?.indexed, false)
    XCTAssertFalse(studio.hasIndex)
    try await snapshot("01-library-not-indexed")

    // Searching before indexing offers to index instead of failing.
    studio.query = "a beach"
    studio.submitSearch()
    XCTAssertTrue(studio.needsIndexPrompt)
    studio.needsIndexPrompt = false
    studio.query = ""

    // Index: one bar from 0 to 100% with a time estimate, then a summary.
    studio.indexFolder()
    try await wait("the progress bar to appear") { studio.activity != nil }
    var samples: [Double] = []
    var sawEstimate = false
    var sawFullBar = false
    var snapped = false
    while studio.notice == nil {
      if let activity = studio.activity {
        samples.append(activity.progress(at: Date()))
        sawEstimate = sawEstimate || activity.secondsRemaining(at: Date()) != nil
        sawFullBar = sawFullBar || activity.isFinished
        if !snapped, activity.fraction > 0.05 {
          snapped = true
          try await snapshot("02-indexing")
        }
      }
      try await Task.sleep(for: .milliseconds(25))
      XCTAssertLessThan(samples.count, 40_000, "indexing never finished")
    }
    XCTAssertLessThan(try XCTUnwrap(samples.first), 0.05, "the bar starts at zero")
    XCTAssertEqual(samples, samples.sorted(), "the bar never moves backwards")
    XCTAssertTrue(sawEstimate, "a time estimate was shown")
    XCTAssertTrue(sawFullBar, "the bar was seen at 100% before the summary replaced it")
    XCTAssertGreaterThan(Set(samples.map { Int($0 * 100) }).count, 5, "it moved through many values")
    try await wait("status refresh") { studio.indexStatus?.indexed == true }
    XCTAssertEqual(studio.indexStatus?.count, 42, "every readable image is searchable")
    XCTAssertEqual(studio.indexStatus?.unreadable, 1, "the corrupt file is reported, not retried forever")
    XCTAssertEqual(studio.indexStatus?.pending, 0)
    XCTAssertEqual(studio.notice?.title, "Index ready")
    try await snapshot("03-indexed")

    // Search by text.
    studio.query = "ocean coastline with waves"
    studio.submitSearch()
    try await wait("first search", timeout: 300) { studio.results != nil && !studio.isSearching }
    let first = try XCTUnwrap(studio.results)
    XCTAssertFalse(first.photos.isEmpty)
    XCTAssertNotNil(first.photos.first?.score)
    try await snapshot("04-search-results")

    // Results must be relevant, not merely present: a text encoder that
    // ignores its input returns the same ranking for every query.
    for (query, expected) in [
      ("a winding road through hills", "Big Sur Road.heic"),
      ("red succulent plants at night", "Big Sur Night Succulents.heic"),
    ] {
      studio.query = query
      studio.submitSearch()
      try await wait("search for \(query)") { studio.results?.title == "“\(query)”" && !studio.isSearching }
      let top = studio.results?.photos.prefix(3).map(\.name) ?? []
      XCTAssertTrue(top.contains(expected), "“\(query)” ranked \(top), expected \(expected) near the top")
    }

    // The model stays loaded, so the next search is fast.
    let started = Date()
    studio.query = "desert sand dunes"
    studio.submitSearch()
    try await wait("warm search") { studio.results?.title == "“desert sand dunes”" && !studio.isSearching }
    let warm = Date().timeIntervalSince(started)
    print("warm search took \(Int(warm * 1000)) ms")
    XCTAssertLessThan(warm, 2.0, "repeat searches must not reload the model")

    // Typing searches on its own after a short pause.
    studio.query = "night sky"
    studio.queryEdited()
    try await wait("live search") { studio.results?.title == "“night sky”" }

    // Search by example, then open the viewer on the best match.
    let example = try XCTUnwrap(studio.library.first { $0.name.hasPrefix("Catalina") })
    studio.searchSimilar(to: example)
    try await wait("similar search") { studio.results?.title == "Similar to \(example.name)" && !studio.isSearching }
    let similar = try XCTUnwrap(studio.results?.photos)
    XCTAssertEqual(similar.first?.path, example.path, "an image is most similar to itself")
    studio.showPreview(of: similar[0], in: similar)
    try await pause(1.5)
    try await snapshot("05-viewer")
    studio.preview = studio.preview?.moved(by: 1)
    XCTAssertEqual(studio.preview?.index, 1)
    studio.preview = nil

    // Clearing returns to the whole library.
    studio.clearSearch()
    XCTAssertNil(studio.results)
    XCTAssertEqual(studio.visiblePhotos.count, 43)

    // Duplicates: the planted copies are found, and one of each is kept.
    studio.page = .duplicates
    studio.findDuplicates()
    try await wait("duplicate search") { studio.duplicates != nil && studio.activity == nil }
    let report = try XCTUnwrap(studio.duplicates)
    XCTAssertGreaterThanOrEqual(report.sets.count, 2)
    XCTAssertTrue(report.sets.contains { $0.isExact })
    XCTAssertTrue(
      report.extras.contains { $0.name == "copy of Catalina Coast.heic" },
      "the copy, not the original, is suggested for removal")
    try await pause(1.0)
    try await snapshot("06-duplicates")

    // Trashing extras updates every list and leaves the keepers.
    let exact = try XCTUnwrap(report.sets.first { $0.isExact })
    studio.moveToTrash(exact.extras)
    try await wait("trash") { studio.library.count == 43 - exact.extras.count }
    XCTAssertTrue(FileManager.default.fileExists(atPath: exact.keeperPath))
    XCTAssertFalse(studio.duplicates?.sets.contains { $0.id == exact.id } ?? true)

    // New files are noticed as not yet searchable.
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: exact.keeperPath), to: folder.appendingPathComponent("added later.heic"))
    studio.page = .library
    studio.reloadLibrary()
    try await wait("stale status") { !studio.isScanning && studio.indexStatus?.pending == 1 }
    try await snapshot("07-new-images-banner")

    // Settings, in the same window: appearance and models.
    studio.page = .settings
    studio.refreshModels()
    try await wait("models") { !studio.models.isEmpty }
    XCTAssertTrue(studio.isInstalled(Self.model))
    try await pause(0.5)
    try await snapshot("08-settings")
    print("snapshots written to \(snapshots.path)")
  }

  /// A careful filter step with the real decision model: it waits to be asked,
  /// reports progress, keeps its answers, and changes what the chain keeps.
  func testACarefulFilterStepLooksAtEachImage() async throws {
    let root = try projectRoot()
    let weights = root.appendingPathComponent("models/mlx/d1-2b/model.safetensors")
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: weights.path), "download Liquid d1-2B in Settings first")
    let folder = try makePhotoFolder()
    let studio = Studio(dataRoot: root, preferencesURL: workspace.appendingPathComponent("preferences.json"))
    show(studio)
    studio.selectModel("clip-vit-b32")
    studio.open(folder)
    try await wait("library scan") { !studio.isScanning && studio.indexStatus != nil }
    studio.indexFolder()
    try await wait("indexing", timeout: 180) { studio.notice != nil && studio.activity == nil }
    await studio.loadModels()
    XCTAssertEqual(studio.decisionModel?.installed, true)

    studio.page = .filter
    studio.addStep(.keep, text: "mountains")
    let step = try XCTUnwrap(studio.filterSteps.last)
    studio.updateStep(step.id) { $0.careful = true }
    studio.runFilter(immediately: true)
    try await wait("the chain") { studio.filterRun != nil && !studio.isFiltering }
    let index = studio.filterSteps.count - 1
    let byDescription = Set(studio.filterRun?.result ?? [])
    let waiting = studio.uncheckedCount(at: index)
    XCTAssertEqual(waiting, 42, "every readable image, and nothing has been asked yet")
    try await snapshot("09-careful-step-waiting")

    studio.lookAtImages(for: step.id)
    try await wait("the model to start") { studio.activity?.kind == .deciding }
    try await wait("the first images", timeout: 120) { (studio.activity?.fraction ?? 0) > 0.2 }
    try capture("10-careful-step-looking")
    try await wait("the model to finish", timeout: 300) {
      studio.activity == nil && !studio.isFiltering && studio.uncheckedCount(at: index) == 0
    }
    let byLooking = Set(studio.filterRun?.result ?? [])
    try await snapshot("11-careful-step-done")
    XCTAssertFalse(byLooking.isEmpty, "some of Apple's wallpapers do show mountains")
    XCTAssertLessThan(byLooking.count, 42, "and most do not")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: IndexStore.directory(in: folder).appendingPathComponent("decisions.sqlite").path),
      "the answers are kept next to the folder's index")
    print(
      "careful step: \(byDescription.count) kept by description, \(byLooking.count) after looking; "
        + "\(byLooking.subtracting(byDescription).count) added, \(byDescription.subtracting(byLooking).count) dropped")
    print("kept: \(byLooking.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted())")
    print("snapshots written to \(snapshots.path)")
  }

  /// Settings and the first-launch chooser say where each model is downloaded from.
  func testModelsAreShownWithWhereTheyDownloadFrom() async throws {
    let root = try projectRoot()
    let engine = NativeEngine(dataRoot: root, remoteModels: URL(string: AppEnvironment.defaultModelsURL))
    let studio = Studio(
      dataRoot: root, preferencesURL: workspace.appendingPathComponent("preferences.json"), engine: engine)
    await studio.loadModels()
    XCTAssertEqual(
      studio.models.map(\.source?.label),
      [String?](repeating: "huggingface.co/ElectricGoal/curio-models", count: studio.models.count))
    XCTAssertEqual(studio.decisionModel?.source?.label, "huggingface.co/LiquidAI/d1-2B-MLX-8bit")

    show(studio)
    studio.page = .settings
    try await snapshot("12-settings")
    window.close()
    show(studio, content: AnyView(ModelSetupView().environmentObject(studio)), width: 520, height: 470)
    try await snapshot("13-first-launch-model-source")
  }

  // MARK: - Fixtures

  private func projectRoot() throws -> URL {
    // …/macos/Tests/CurioTests/EndToEndTests.swift → the checkout root
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let model = root.appendingPathComponent("models/coreml/\(Self.model)/model.json")
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: model.path), "run scripts/convert-models.sh first")
    return root
  }

  /// 40 sample photos in two subfolders, two exact copies, one corrupt file
  /// and one hidden file: 43 visible images, 42 of them readable.
  private func makePhotoFolder() throws -> URL {
    let manager = FileManager.default
    try XCTSkipUnless(manager.fileExists(atPath: Self.samples.path), "no system sample images")
    let folder = workspace.appendingPathComponent("photos")
    let names = try manager.contentsOfDirectory(atPath: Self.samples.path)
      .filter { $0.hasSuffix(".heic") }.sorted().prefix(40)
    try XCTSkipUnless(names.count == 40, "expected 40 sample images, found \(names.count)")
    for (index, name) in names.enumerated() {
      let directory = folder.appendingPathComponent(index.isMultiple(of: 2) ? "coast" : "hills")
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      try manager.copyItem(at: Self.samples.appendingPathComponent(name), to: directory.appendingPathComponent(name))
    }
    for name in ["Catalina Coast.heic", "Big Sur Road.heic"] where names.contains(name) {
      try manager.copyItem(at: Self.samples.appendingPathComponent(name), to: folder.appendingPathComponent("copy of " + name))
    }
    try Data("not an image".utf8).write(to: folder.appendingPathComponent("broken.jpg"))
    try Data("x".utf8).write(to: folder.appendingPathComponent(".hidden.png"))
    return folder
  }

  // MARK: - Window and timing

  private func show(_ studio: Studio) {
    show(studio, content: AnyView(StudioView().environmentObject(studio)), width: 1280, height: 820)
  }

  /// Puts any of the app's screens in the window the snapshots are taken of.
  private func show(_ studio: Studio, content: AnyView, width: CGFloat, height: CGFloat) {
    let host = NSHostingView(rootView: content)
    // Keep the given window size instead of growing to fit the content.
    host.sizingOptions = []
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      // As the app's own window: no title bar, the content reaching the top edge.
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    window.orderFrontRegardless()
  }

  /// Renders the window in light, then in dark, so both appearances are reviewed.
  private func snapshot(_ name: String) async throws {
    try await pause(0.6)  // let thumbnails and layout settle
    try capture(name)
    window.appearance = NSAppearance(named: .darkAqua)
    try await pause(0.3)
    try capture(name + "-dark")
    window.appearance = NSAppearance(named: .aqua)
    try await pause(0.1)
  }

  private func capture(_ name: String) throws {
    // The window's frame view, so its close, minimise and zoom buttons are in the picture.
    let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: snapshots.appendingPathComponent(name + ".png"))
  }

  private func pause(_ seconds: Double) async throws {
    try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
  }

  private func wait(
    _ what: String, timeout: TimeInterval = 60, until condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else {
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(40))
    }
  }
}
