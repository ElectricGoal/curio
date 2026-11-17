import Foundation
import XCTest

@testable import CurioKit

/// A decision model as installed in the checkout (`models/mlx/<alias>`) and
/// the reference outputs `scripts/d1-reference.sh` writes next to it.
enum D1Fixtures {
  static let alias = "d1-2b"
  /// The same model packed in four bits: its own weights, its own reference answers.
  static let compactAlias = "d1-2b-4bit"

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

  static var directory: URL { directory(of: alias) }

  static func directory(of alias: String) -> URL {
    ModelFixtures.checkout.appendingPathComponent("models/mlx").appendingPathComponent(alias)
  }

  static var picture: URL { picture(of: alias) }

  static func picture(of alias: String) -> URL {
    directory(of: alias).appendingPathComponent("fixtures-picture.png")
  }

  static var shaders: URL {
    ModelFixtures.checkout.appendingPathComponent("macos/.build").appendingPathComponent(MLXShaders.fileName)
  }

  /// The reference outputs, or a skip when the model is not set up on this machine.
  static func reference(of alias: String = alias) throws -> Reference {
    let directory = directory(of: alias)
    let url = directory.appendingPathComponent("fixtures.json")
    let files = [url, directory.appendingPathComponent(D1DecisionModel.weightsFile), shaders]
    try XCTSkipUnless(
      files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
      "install \(alias), then run scripts/build-mlx-shaders.sh and scripts/d1-reference.sh \(alias)")
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
  private static let loadedCompact = Task { () -> D1DecisionModel in
    try await D1DecisionModel.load(
      alias: compactAlias, directory: directory(of: compactAlias), shaders: shaders)
  }

  static func model() async throws -> D1DecisionModel {
    _ = try reference()
    return try await loaded.value
  }

  static func compactModel() async throws -> D1DecisionModel {
    _ = try reference(of: compactAlias)
    return try await loadedCompact.value
  }
}
