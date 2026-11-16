import XCTest

@testable import CurioKit

/// Where a model comes from, as the app tells the user.
final class ModelSourceTests: XCTestCase {
  func testAHuggingFaceDownloadIsNamedByItsRepositoryAndLinksToItsFiles() throws {
    let base = try XCTUnwrap(
      URL(string: "https://huggingface.co/ElectricGoal/curio-models/resolve/main/mobileclip-s4"))
    let source = try XCTUnwrap(ModelSource(downloadBase: base))
    XCTAssertEqual(source.label, "huggingface.co/ElectricGoal/curio-models")
    XCTAssertEqual(
      source.page.absoluteString, "https://huggingface.co/ElectricGoal/curio-models/tree/main/mobileclip-s4")
  }

  func testAPinnedRevisionLinksToThatRevision() throws {
    let entry = try XCTUnwrap(DecisionCatalog.entry(DecisionCatalog.defaultAlias))
    let source = try XCTUnwrap(ModelSource(downloadBase: entry.source))
    XCTAssertEqual(source.label, "huggingface.co/LiquidAI/d1-2B-MLX-8bit")
    XCTAssertEqual(
      source.page.absoluteString,
      "https://huggingface.co/LiquidAI/d1-2B-MLX-8bit/tree/3247d0483b11e5da31fa10e7979c23252fbe3580")
  }

  func testAnotherHostIsShownAsItIs() throws {
    let base = try XCTUnwrap(URL(string: "https://models.example.com/curio/clip-vit-b32"))
    let source = try XCTUnwrap(ModelSource(downloadBase: base))
    XCTAssertEqual(source.label, "models.example.com/curio/clip-vit-b32")
    XCTAssertEqual(source.page, base)
    // Something that only looks like a repository address is not rewritten.
    let odd = try XCTUnwrap(URL(string: "https://huggingface.co/resolve"))
    XCTAssertEqual(ModelSource(downloadBase: odd)?.page, odd)
  }

  func testAFolderOnThisMacIsShownByItsPath() throws {
    let source = try XCTUnwrap(ModelSource(downloadBase: URL(fileURLWithPath: "/Volumes/Models/curio")))
    XCTAssertEqual(source.label, "/Volumes/Models/curio")
    XCTAssertTrue(source.page.isFileURL)
  }

  func testTheModelListSaysWhereEachModelDownloadsFrom() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("curio-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let remote = try XCTUnwrap(URL(string: "https://huggingface.co/ElectricGoal/curio-models/resolve/main"))
    let hosted = ModelLibrary(installDirectory: root, remote: remote).models()
    XCTAssertEqual(hosted.map(\.source?.label), [String?](repeating: "huggingface.co/ElectricGoal/curio-models", count: hosted.count))
    XCTAssertTrue(hosted[0].source?.page.absoluteString.hasSuffix("/tree/main/\(hosted[0].alias)") ?? false)

    let offline = ModelLibrary(installDirectory: root).models()
    XCTAssertTrue(offline.allSatisfy { $0.source == nil }, "nothing to download from, nothing to name")

    let decision = DecisionLibrary(installDirectory: root).models()
    XCTAssertEqual(decision.first?.source?.label, "huggingface.co/LiquidAI/d1-2B-MLX-8bit")
  }

  func testAModelListWithoutSourcesStillDecodes() throws {
    let json = #"{"alias":"a","id":"a","name":"A","family":"coreml","summary":"","default":true,"installed":false,"available":true,"availabilityMessage":"","size":0}"#
    XCTAssertNil(try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8)).source)
  }
}
