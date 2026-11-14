import Foundation

/// What the engine needs to know to run one converted model: the contents of
/// `model.json`, written next to the Core ML packages by the conversion script.
public struct ModelManifest: Codable, Equatable, Sendable {
  public static let fileName = "model.json"
  public static let supportedFormat = 1

  public let format: Int
  public let alias: String
  public let name: String
  /// Length of the embeddings the model produces.
  public let dim: Int
  /// Side of the square image the image encoder expects, in pixels.
  public let imageSize: Int
  public let contextLength: Int
  public let padToken: Int32
  public let startToken: Int32
  public let endToken: Int32
  public let precision: String
  public let license: String
  public let imageModel: String
  public let textModel: String
  public let merges: String

  public init(
    format: Int, alias: String, name: String, dim: Int, imageSize: Int, contextLength: Int,
    padToken: Int32, startToken: Int32, endToken: Int32, precision: String, license: String,
    imageModel: String, textModel: String, merges: String
  ) {
    self.format = format
    self.alias = alias
    self.name = name
    self.dim = dim
    self.imageSize = imageSize
    self.contextLength = contextLength
    self.padToken = padToken
    self.startToken = startToken
    self.endToken = endToken
    self.precision = precision
    self.license = license
    self.imageModel = imageModel
    self.textModel = textModel
    self.merges = merges
  }

  public static func load(from directory: URL) throws -> ModelManifest {
    let url = directory.appendingPathComponent(fileName)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let manifest: ModelManifest
    do {
      manifest = try decoder.decode(ModelManifest.self, from: Data(contentsOf: url))
    } catch {
      throw EngineError.failed("The model in \(directory.lastPathComponent) is incomplete or damaged.")
    }
    guard manifest.format == supportedFormat else {
      throw EngineError.failed(
        "The model in \(directory.lastPathComponent) was made for a different version of this app.")
    }
    guard manifest.isPlausible else {
      throw EngineError.failed("The model in \(directory.lastPathComponent) is incomplete or damaged.")
    }
    return manifest
  }

  /// Sizes the engine can allocate for, and file names that stay inside the
  /// model's own folder. A manifest is read from disk, so it is not trusted.
  var isPlausible: Bool {
    let names = [imageModel, textModel, merges]
    return (1...Self.largestDimension).contains(dim)
      && (1...Self.largestImageSide).contains(imageSize)
      && (1...Self.largestContext).contains(contextLength)
      && names.allSatisfy { !$0.isEmpty && !$0.contains("/") && !$0.hasPrefix(".") }
  }

  private static let largestDimension = 16_384
  private static let largestImageSide = 4_096
  private static let largestContext = 4_096
}
