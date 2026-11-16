import Foundation
import MLX

/// A model that answers yes/no questions about a picture.
///
/// Unlike an `EmbeddingModel`, it looks at the picture and the question
/// together, so it can tell "a product on a white background" from a logo on
/// one. It is far slower: a fraction of a second per picture, not microseconds.
public protocol DecisionModel: Sendable {
  var alias: String { get }
  /// How likely the answer to each question is "yes", from 0 to 1, in order.
  func decide(image: URL, questions: [String]) async throws -> [Double]
}

/// A Liquid AI d1 checkpoint in MLX format, run on the GPU inside the app.
public actor D1DecisionModel: DecisionModel {
  /// Buffers MLX may keep for reuse between pictures. Without a limit it holds
  /// on to gigabytes; this is enough for pictures of the size used here.
  static let bufferCacheBytes = 512 * 1024 * 1024
  static let weightsFile = "model.safetensors"
  static let tokenizerFile = "tokenizer.json"

  public nonisolated let alias: String
  let network: D1Network
  let prompt: D1Prompt
  nonisolated let layout: D1PictureLayout
  let calibration: D1Calibration
  /// Questions answered together in one pass; more are split over several passes.
  private let questionsPerPass = 16

  private init(
    alias: String, network: D1Network, prompt: D1Prompt, layout: D1PictureLayout,
    calibration: D1Calibration
  ) {
    self.alias = alias
    self.network = network
    self.prompt = prompt
    self.layout = layout
    self.calibration = calibration
  }

  /// Loads the checkpoint in `directory`: `config.json`, `tokenizer.json`,
  /// `model.safetensors` and, when present, `calibration.json`. `shaders` is
  /// MLX's compiled Metal library (see `MLXShaders`).
  public static func load(alias: String, directory: URL, shaders: URL, longestSide: Int = 384)
    async throws -> D1DecisionModel
  {
    guard FileManager.default.fileExists(atPath: shaders.path) else {
      throw EngineError.failed(MLXShaders.missingMessage)
    }
    GPU.metallib = shaders
    let config = try D1Config.load(from: directory)
    let tokenizer = try D1Tokenizer(contentsOf: directory.appendingPathComponent(tokenizerFile))
    let arrays: [String: MLXArray]
    do {
      arrays = try loadArrays(url: directory.appendingPathComponent(weightsFile))
    } catch {
      throw EngineError.failed("The decision model's weights could not be read. Download it again.")
    }
    Memory.cacheLimit = bufferCacheBytes
    // Read from disk now, not in the middle of the first decision.
    try Self.reportingFailures { eval(Array(arrays.values)) }
    var layout = D1PictureLayout()
    layout.patch = config.vision.patchSize
    layout.merge = config.vision.merge
    layout.frames = config.vision.frames
    layout.channels = config.vision.channels
    layout.maxPixels = config.visionMaxPixels
    layout.longestSide = longestSide
    return D1DecisionModel(
      alias: alias,
      network: D1Network(config: config, weights: D1Weights(arrays: arrays, quantization: config.quantization)),
      prompt: try D1Prompt(tokenizer: tokenizer), layout: layout,
      calibration: D1Calibration.load(from: directory))
  }

  public func decide(image: URL, questions: [String]) async throws -> [Double] {
    guard !questions.isEmpty else { return [] }
    let picture = try layout.picture(at: image)
    return try Self.reportingFailures { try answers(for: picture, questions: questions) }
  }

  /// MLX reports trouble (out of memory, a GPU fault) through a handler that
  /// stops the app by default; here it becomes an error the app can show.
  private static func reportingFailures<Result>(_ work: () throws -> Result) throws -> Result {
    do {
      return try withError(work)
    } catch let error as EngineError {
      throw error
    } catch let error as ImagePreprocessor.Failure {
      throw error
    } catch {
      throw EngineError.failed("The decision model stopped: \(error.localizedDescription)")
    }
  }

  /// The picture is read by the vision tower once, however many questions follow.
  func answers(for picture: D1Picture, questions: [String]) throws -> [Double] {
    let features = try network.features(of: picture)
    let tokens = prompt.yesTokens + prompt.noTokens
    var answers: [Double] = []
    for start in stride(from: 0, to: questions.count, by: questionsPerPass) {
      let group = Array(questions[start..<min(start + questionsPerPass, questions.count)])
      let row = try prompt.row(imageTokens: features.dim(0), questions: group)
      let hidden = try network.hidden(for: row, features: features, imageToken: prompt.imageTokenID)
      for scores in try network.scores(hidden: hidden, slots: row.slots, tokens: tokens) {
        let yes = scores[..<prompt.yesTokens.count].max() ?? 0
        let no = scores[prompt.yesTokens.count...].max() ?? 0
        answers.append(calibration.yesProbability(yes: Double(yes), no: Double(no)))
      }
    }
    return answers
  }

  /// The first `count` values of every token the vision tower makes of a picture; for tests.
  func featureRows(of image: URL, count: Int) throws -> [[Float]] {
    let picture = try layout.picture(at: image)
    return try Self.reportingFailures {
      let features = try network.features(of: picture).asType(.float32)
      let width = features.dim(1)
      let flat = features.asArray(Float.self)
      return (0..<features.dim(0)).map { Array(flat[($0 * width)..<($0 * width + count)]) }
    }
  }

  /// Proves MLX can compute on this Mac's GPU with the shaders at `shaders`:
  /// what every decision depends on, checked without a model.
  public static func checkGPU(shaders: URL) throws {
    guard FileManager.default.fileExists(atPath: shaders.path) else {
      throw EngineError.failed(MLXShaders.missingMessage)
    }
    GPU.metallib = shaders
    let sum = try reportingFailures { () -> Float in
      let values = MLXArray([1, 2, 3] as [Float])
      return matmul(values.reshaped([1, 3]), values.reshaped([3, 1])).item(Float.self)
    }
    guard sum == 14 else { throw EngineError.failed("The GPU gave a wrong answer to a simple sum.") }
  }

  /// Gives back the buffers MLX kept; call when the model is no longer needed.
  public static func releaseBuffers() {
    Memory.clearCache()
  }
}
