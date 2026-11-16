import Foundation
import XCTest

@testable import CurioKit

/// The decision model as installed in the checkout (`models/mlx/d1-2b`) and
/// the reference outputs `scripts/d1-reference.sh` writes next to it.
enum D1Fixtures {
  static let alias = "d1-2b"

  struct Reference: Decodable {
    struct TokenCase: Decodable {
      let text: String
      let ids: [Int]
    }
    struct EscapeCase: Decodable {
      let text: String
      let suffix: String
    }
    struct Sample: Decodable {
      let index: Int
      let values: [Float]
    }
    let tokenizer: [TokenCase]
    let escaped: [EscapeCase]
    let questions: [String]
    let grid: [Int]
    let patchValues: Int
    let patchSum: Double
    let patches: [Sample]
    let featuresShape: [Int]
    let features: [Sample]
    let ids: [Int]
    let stateLength: Int
    let groups: [Int]
    let slots: [Int]
    let fullMaskTrue: Int
    let yesTokens: [Int]
    let noTokens: [Int]
    let scores: [[Float]]
    let temperature: Double
    let answers: [Double]
    let answerAlone: Double
  }

  static var directory: URL {
    ModelFixtures.checkout.appendingPathComponent("models/mlx").appendingPathComponent(alias)
  }

  static var picture: URL { directory.appendingPathComponent("fixtures-picture.png") }

  static var shaders: URL {
    ModelFixtures.checkout.appendingPathComponent("macos/.build").appendingPathComponent(MLXShaders.fileName)
  }

  /// The reference outputs, or a skip when the model is not set up on this machine.
  static func reference() throws -> Reference {
    let url = directory.appendingPathComponent("fixtures.json")
    let files = [url, directory.appendingPathComponent(D1DecisionModel.weightsFile), shaders]
    try XCTSkipUnless(
      files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
      "install d1-2b, then run scripts/build-mlx-shaders.sh and scripts/d1-reference.sh")
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(Reference.self, from: Data(contentsOf: url))
  }

  static func tokenizer() throws -> D1Tokenizer {
    _ = try reference()
    return try D1Tokenizer(contentsOf: directory.appendingPathComponent(D1DecisionModel.tokenizerFile))
  }

  /// Loaded once: reading 2 GB of weights for every test would take minutes.
  private static let loaded = Task { () -> D1DecisionModel in
    try await D1DecisionModel.load(alias: alias, directory: directory, shaders: shaders)
  }

  static func model() async throws -> D1DecisionModel {
    _ = try reference()
    return try await loaded.value
  }
}
