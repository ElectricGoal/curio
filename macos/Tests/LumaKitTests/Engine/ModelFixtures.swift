import Foundation
import XCTest

@testable import LumaKit

/// Converted models and their reference outputs, produced by
/// `scripts/convert-models.sh` into `models/coreml/` in the checkout.
enum ModelFixtures {
  static let aliases = ["mobileclip-s4", "clip-vit-b32"]

  struct Reference: Decodable {
    struct TokenCase: Decodable {
      let text: String
      let tokens: [Int32]
    }
    struct TextCase: Decodable {
      let text: String
      let embedding: [Float]
    }
    struct ImageCase: Decodable {
      let name: String
      let embedding: [Float]
    }
    let tokenizer: [TokenCase]
    let text: [TextCase]
    let image: [ImageCase]
  }

  static var checkout: URL {
    // …/macos/Tests/LumaKitTests/Engine/ModelFixtures.swift → the checkout root
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }

  static var modelsDirectory: URL { checkout.appendingPathComponent("models/coreml") }

  /// The model's folder, or a skip when it has not been converted on this machine.
  static func directory(_ alias: String) throws -> URL {
    let directory = modelsDirectory.appendingPathComponent(alias)
    try XCTSkipUnless(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(ModelManifest.fileName).path),
      "run scripts/convert-models.sh to test against \(alias)")
    return directory
  }

  static func reference(_ alias: String) throws -> Reference {
    let url = try directory(alias).appendingPathComponent("fixtures.json")
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
  }

  static func tokenizer(_ alias: String) throws -> CLIPTokenizer {
    let directory = try directory(alias)
    let manifest = try ModelManifest.load(from: directory)
    return try CLIPTokenizer(
      mergesFile: directory.appendingPathComponent(manifest.merges), manifest: manifest)
  }
}
