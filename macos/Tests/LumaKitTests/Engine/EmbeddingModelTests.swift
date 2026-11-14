import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import LumaKit

/// The converted models, run through the Swift pipeline, against PyTorch's outputs.
final class EmbeddingModelTests: XCTestCase {
  private static var loaded: [String: CoreMLEmbeddingModel] = [:]
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("luma-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  private func model(_ alias: String) async throws -> CoreMLEmbeddingModel {
    if let model = Self.loaded[alias] { return model }
    let directory = try ModelFixtures.directory(alias)
    let model = try await CoreMLEmbeddingModel.load(
      directory: directory,
      cache: ModelFixtures.checkout.appendingPathComponent(".cache/compiled/\(alias)"))
    Self.loaded[alias] = model
    return model
  }

  func testTextEmbeddingsMatchPyTorch() async throws {
    for alias in ModelFixtures.aliases {
      let model = try await model(alias)
      for example in try ModelFixtures.reference(alias).text {
        let embedding = try await model.embed(text: example.text)
        XCTAssertEqual(embedding.count, model.manifest.dim)
        XCTAssertGreaterThan(
          VectorMath.dot(embedding, example.embedding), 0.999, "\(alias): “\(example.text)”")
      }
    }
  }

  func testImageEmbeddingsMatchPyTorch() async throws {
    for alias in ModelFixtures.aliases {
      let model = try await model(alias)
      let side = model.manifest.imageSize
      let plane = side * side
      // The two synthetic pictures the conversion script recorded outputs for.
      var flat = [Float](repeating: 0, count: 3 * plane)
      for index in 0..<plane {
        flat[index] = 0.8
        flat[plane + index] = 0.2
        flat[2 * plane + index] = 0.1
      }
      var gradient = [Float](repeating: 0, count: 3 * plane)
      for index in 0..<(3 * plane) { gradient[index] = Float(index % side) / Float(side - 1) }
      let reference = try ModelFixtures.reference(alias).image
      for (name, tensor) in [("flat", flat), ("gradient", gradient)] {
        let expected = try XCTUnwrap(reference.first { $0.name == name }).embedding
        let embedding = try await model.embed(image: tensor)
        XCTAssertGreaterThan(VectorMath.dot(embedding, expected), 0.99, "\(alias): \(name)")
      }
    }
  }

  func testDescribingAColourFindsThatColourFromAFile() async throws {
    let colours: [(String, CGFloat, CGFloat, CGFloat)] = [
      ("red", 0.86, 0.12, 0.12), ("green", 0.12, 0.67, 0.24), ("blue", 0.12, 0.24, 0.86),
    ]
    for alias in ModelFixtures.aliases {
      let model = try await model(alias)
      var images: [[Float]] = []
      for (name, red, green, blue) in colours {
        let url = scratch.appendingPathComponent("\(name).png")
        try Self.writePNG(to: url, width: 300, height: 200, red: red, green: green, blue: blue)
        let prepared = try ImagePreprocessor.prepare(url, side: model.manifest.imageSize)
        XCTAssertEqual(prepared.width, 300)
        XCTAssertEqual(prepared.height, 200)
        XCTAssertEqual(prepared.sha1.count, 40)
        images.append(try await model.embed(image: prepared.tensor))
      }
      for (index, colour) in colours.enumerated() {
        let query = try await model.embed(text: "a solid \(colour.0) square")
        let scores = images.map { VectorMath.dot($0, query) }
        XCTAssertEqual(scores.firstIndex(of: scores.max()!), index, "\(alias): \(colour.0)")
      }
    }
  }

  func testWrongSizedInputIsRejectedNotMisread() async throws {
    let model = try await model("clip-vit-b32")
    do {
      _ = try await model.embed(image: [0.5, 0.5, 0.5])
      XCTFail("expected an error")
    } catch {
      XCTAssertTrue(error is EngineError)
    }
  }

  static func writePNG(
    to url: URL, width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat,
    alpha: CGFloat = 1
  ) throws {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // sRGB, the space the file is tagged with, so the values round-trip unchanged.
    context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }
}

final class ImagePreprocessorTests: XCTestCase {
  func testTransparentAreasBecomeWhiteNotBlack() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: url) }
    try EmbeddingModelTests.writePNG(to: url, width: 40, height: 40, red: 0, green: 0, blue: 0, alpha: 0)

    let prepared = try ImagePreprocessor.prepare(url, side: 8)

    XCTAssertEqual(prepared.tensor.count, 3 * 8 * 8)
    XCTAssertEqual(prepared.tensor.min() ?? 0, 1, accuracy: 0.01, "fully transparent reads as white")
  }

  func testPlanesAreRedThenGreenThenBlue() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: url) }
    try EmbeddingModelTests.writePNG(to: url, width: 64, height: 16, red: 1, green: 0.5, blue: 0)

    let tensor = try ImagePreprocessor.prepare(url, side: 4).tensor

    XCTAssertEqual(tensor[0], 1, accuracy: 0.02)
    XCTAssertEqual(tensor[16], 0.5, accuracy: 0.02)
    XCTAssertEqual(tensor[32], 0, accuracy: 0.02)
  }

  func testUnreadableFilesAreReportedByName() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    try? Data("not an image".utf8).write(to: url)
    XCTAssertThrowsError(try ImagePreprocessor.prepare(url, side: 8)) { error in
      XCTAssertTrue(error.localizedDescription.contains("broken-"))
    }
  }
}

final class VectorMathTests: XCTestCase {
  func testScoresAndRanking() {
    let matrix: [Float] = [1, 0, 0, 1, 0.6, 0.8]  // three unit rows of dimension 2
    let scores = VectorMath.scores(matrix: matrix, rows: 3, dimension: 2, query: [0, 1])
    XCTAssertEqual(scores, [0, 1, 0.8])
    XCTAssertEqual(VectorMath.top(scores, limit: 2), [1, 2])
    XCTAssertEqual(VectorMath.scores(matrix: matrix, rows: 3, dimension: 2, query: [1]), [], "wrong size")
  }

  func testBlockScoresMatchRowByRow() {
    let matrix: [Float] = [1, 0, 0, 1, 0.6, 0.8]
    let flipped = VectorMath.transposed(matrix, rows: 3, dimension: 2)
    XCTAssertEqual(flipped, [1, 0, 0.6, 0, 1, 0.8])
    let block = VectorMath.scores(
      matrix: matrix, transposed: flipped, rows: 3, dimension: 2, blockStart: 1, blockCount: 2)
    XCTAssertEqual(block.count, 6)
    XCTAssertEqual(block[0], 0, accuracy: 1e-6)  // row 1 · row 0
    XCTAssertEqual(block[1], 1, accuracy: 1e-6)  // row 1 · row 1
    XCTAssertEqual(block[5], 1, accuracy: 1e-6)  // row 2 · row 2
    XCTAssertEqual(block[4], 0.8, accuracy: 1e-6)  // row 2 · row 1
  }

  func testNormalisingMakesUnitLengthAndLeavesZeroAlone() {
    XCTAssertEqual(VectorMath.normalized([3, 4]), [0.6, 0.8])
    XCTAssertEqual(VectorMath.normalized([0, 0]), [0, 0])
  }
}
