import XCTest

@testable import CurioKit

final class CurationTests: XCTestCase {
  private let beach = CurationLabel(name: "Beach", prompt: "beach", kind: .tag)
  private let food = CurationLabel(name: "Food", prompt: "food", kind: .tag)
  private let screenshot = CurationLabel(name: "Screenshots", prompt: "screen", kind: .junk)
  private let receipts = Labels.album("receipts")

  /// Rows of cosines in label order: beach, food, screenshot, receipts.
  private func curation(_ rows: [String: [Float]]) -> Curation {
    let paths = rows.keys.sorted()
    return Curation(
      scores: PromptScores(paths: paths, prompts: 4, scores: paths.flatMap { rows[$0]! }, model: "m"),
      labels: [beach, food, screenshot, receipts])
  }

  func testClearMatchesAreTaggedAndWeakOnesAreNot() {
    let result = curation([
      "/a.jpg": [0.30, 0.20, 0.10, 0.10],  // clearly a beach
      "/b.jpg": [0.25, 0.25, 0.10, 0.10],  // half beach, half food: both tags
      "/c.jpg": [0.10, 0.12, 0.35, 0.10],  // a screenshot
    ])
    XCTAssertEqual(result.tags(of: "/a.jpg"), [beach])
    XCTAssertEqual(Set(result.tags(of: "/b.jpg")), [beach, food])
    XCTAssertEqual(result.tags(of: "/c.jpg"), [], "clutter is not a tag")
    XCTAssertEqual(result.paths(for: screenshot), ["/c.jpg"])
    XCTAssertEqual(result.paths(for: beach).first, "/a.jpg", "best match first")
    XCTAssertEqual(result.imageCount, 3)
  }

  func testClutterNeedsToBeTheClearBestLabel() {
    let result = curation(["/x.jpg": [0.30, 0.10, 0.299, 0.10]])
    XCTAssertEqual(result.paths(for: screenshot), [], "a beach that looks a bit like a screen is kept")
  }

  func testAlbumsTakeImagesTheyMatchAboutAsWellAsTheBestLabel() {
    let result = curation([
      "/receipt.jpg": [0.10, 0.20, 0.25, 0.30],
      "/close.jpg": [0.10, 0.10, 0.25, 0.245],
      "/beach.jpg": [0.30, 0.10, 0.10, 0.15],
    ])
    XCTAssertEqual(result.paths(for: receipts), ["/receipt.jpg", "/close.jpg"])
  }

  func testRemovingDropsFilesEverywhere() {
    let result = curation(["/a.jpg": [0.30, 0.20, 0.10, 0.10]]).removing(["/a.jpg"])
    XCTAssertEqual(result.paths(for: beach), [])
    XCTAssertEqual(result.tags(of: "/a.jpg"), [])
  }

  func testAlbumsArePhrasedTheWayTheModelMatchesBest() {
    XCTAssertEqual(Labels.album("flowers").prompt, "a photo of flowers")
    XCTAssertEqual(Labels.album("A dog on a sofa").prompt, "A dog on a sofa")
  }

  func testRefinementParsing() {
    let refinement = SearchRefinement(parsing: " at night, -people , without cars, no snow,, ")
    XCTAssertEqual(refinement.adding, ["at night"])
    XCTAssertEqual(refinement.removing, ["people", "cars", "snow"])
    XCTAssertEqual(refinement.summary, "+ at night − people − cars − snow")
    XCTAssertTrue(SearchRefinement(parsing: " , - ").isEmpty)
  }

  func testScoresAgainstSeveralQueries() {
    // Two rows, two queries: each row's dot product with each query.
    let scores = VectorMath.scores(
      matrix: [1, 0, 0, 1], rows: 2, dimension: 2, queries: [[1, 0], [0.6, 0.8]])
    XCTAssertEqual(scores, [1, 0.6, 0, 0.8])
  }

  func testSimilarShotsKeepTheBestLookingButResavesKeepTheLargest() {
    let size: (String) -> Int64 = { ["burst1.jpg": 90, "burst2.jpg": 50, "big.jpg": 90, "small.jpg": 10][$0] ?? 0 }
    let quality: (String) -> Float? = { ["burst1.jpg": 0.01, "burst2.jpg": 0.05, "big.jpg": 0, "small.jpg": 1][$0] }
    let groups = DuplicateFinder.groups(
      identical: [], near: [(paths: ["burst1.jpg", "burst2.jpg"], similarity: 0.95), (paths: ["big.jpg", "small.jpg"], similarity: 0.99)],
      size: size, quality: quality)
    let burst = groups.first { $0.duplicates.contains("burst1.jpg") || $0.keeper == "burst1.jpg" }!
    XCTAssertEqual(burst.keeper, "burst2.jpg")
    XCTAssertTrue(burst.isBestShot)
    let resave = groups.first { $0.keeper == "big.jpg" || $0.keeper == "small.jpg" }!
    XCTAssertEqual(resave.keeper, "big.jpg", "a re-save keeps the largest file")
    XCTAssertFalse(resave.isBestShot)
  }
}
