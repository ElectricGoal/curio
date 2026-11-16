import CoreML
import Foundation

/// A model that maps images and text into one shared space of unit vectors.
///
/// The engine only talks to this protocol, so the inference technology behind
/// it (Core ML today) can be replaced without touching indexing or search.
public protocol EmbeddingModel: Sendable {
  var manifest: ModelManifest { get }
  /// `tensor` holds red, green and blue planes in 0…1 (see `ImagePreprocessor`).
  func embed(image tensor: [Float]) async throws -> [Float]
  func embed(text: String) async throws -> [Float]
}

/// Runs a converted model with Core ML.
public final class CoreMLEmbeddingModel: EmbeddingModel, @unchecked Sendable {
  /// The GPU reproduces the reference model's rankings; the Neural Engine is
  /// faster but was measurably less faithful, so it is not used.
  private static let computeUnits = MLComputeUnits.cpuAndGPU
  private static let imageInput = "image"
  private static let textInput = "tokens"
  private static let output = "embedding"

  public let manifest: ModelManifest
  private let tokenizer: CLIPTokenizer
  private let imageModel: MLModel
  private let textModel: MLModel

  private init(
    manifest: ModelManifest, tokenizer: CLIPTokenizer, imageModel: MLModel, textModel: MLModel
  ) {
    self.manifest = manifest
    self.tokenizer = tokenizer
    self.imageModel = imageModel
    self.textModel = textModel
  }

  /// Loads the model stored in `directory`. Core ML compiles each package once;
  /// the compiled form is kept in `cache` for later launches.
  public static func load(directory: URL, cache: URL) async throws -> CoreMLEmbeddingModel {
    let manifest = try ModelManifest.load(from: directory)
    let tokenizer = try CLIPTokenizer(
      mergesFile: directory.appendingPathComponent(manifest.merges), manifest: manifest)
    let configuration = MLModelConfiguration()
    configuration.computeUnits = computeUnits
    do {
      let image = try await compiled(
        directory.appendingPathComponent(manifest.imageModel), cache: cache, name: "image")
      let text = try await compiled(
        directory.appendingPathComponent(manifest.textModel), cache: cache, name: "text")
      return CoreMLEmbeddingModel(
        manifest: manifest, tokenizer: tokenizer,
        imageModel: try MLModel(contentsOf: image, configuration: configuration),
        textModel: try MLModel(contentsOf: text, configuration: configuration))
    } catch let error as EngineError {
      throw error
    } catch {
      throw EngineError.failed(
        "\(manifest.name) could not be loaded: \(error.localizedDescription)")
    }
  }

  /// The compiled model for `package`, compiling it if the cached copy is
  /// missing or older than the package.
  private static func compiled(_ package: URL, cache: URL, name: String) async throws -> URL {
    let manager = FileManager.default
    let destination = cache.appendingPathComponent(name + ".mlmodelc")
    let modified: (URL) -> Date? = {
      (try? manager.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
    }
    if let built = modified(destination), let source = modified(package), built >= source {
      return destination
    }
    let temporary = try await MLModel.compileModel(at: package)
    try manager.createDirectory(at: cache, withIntermediateDirectories: true)
    try? manager.removeItem(at: destination)
    try manager.moveItem(at: temporary, to: destination)
    return destination
  }

  public func embed(image tensor: [Float]) async throws -> [Float] {
    let side = manifest.imageSize
    guard tensor.count == 3 * side * side else {
      throw EngineError.failed("The image was prepared for a different model.")
    }
    let input = try MLMultiArray(
      shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
    tensor.withUnsafeBufferPointer { source in
      input.dataPointer.assumingMemoryBound(to: Float.self)
        .update(from: source.baseAddress!, count: tensor.count)
    }
    return try await run(imageModel, input: Self.imageInput, value: input)
  }

  public func embed(text: String) async throws -> [Float] {
    let tokens = tokenizer.tokenize(text)
    let input = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
    tokens.withUnsafeBufferPointer { source in
      input.dataPointer.assumingMemoryBound(to: Int32.self)
        .update(from: source.baseAddress!, count: tokens.count)
    }
    return try await run(textModel, input: Self.textInput, value: input)
  }

  private func run(_ model: MLModel, input name: String, value: MLMultiArray) async throws -> [Float] {
    let features = try MLDictionaryFeatureProvider(dictionary: [name: value])
    let result = try await model.prediction(from: features)
    guard let array = result.featureValue(for: Self.output)?.multiArrayValue,
      array.count == manifest.dim
    else { throw EngineError.failed("\(manifest.name) returned an unexpected result.") }
    let vector = (0..<manifest.dim).map { array[$0].floatValue }
    // Unit length is what makes a dot product a cosine similarity.
    return VectorMath.normalized(vector)
  }
}
