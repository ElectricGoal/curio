import Foundation

/// The parts of a d1 checkpoint's `config.json` this app reads.
struct D1Config: Decodable, Sendable {
  struct Rotation: Decodable, Sendable {
    let theta: Float
    /// Share of each attention head that is rotated; the rest carries no position.
    let partialFactor: Float?

    enum CodingKeys: String, CodingKey {
      case theta = "rope_theta"
      case partialFactor = "partial_rotary_factor"
    }
  }

  struct Text: Decodable, Sendable {
    enum LayerKind: String, Decodable, Sendable {
      case convolution = "conv"
      case fullAttention = "full_attention"
      case slidingAttention = "sliding_attention"
    }

    let hiddenSize: Int
    let headCount: Int
    let keyValueHeadCount: Int
    let headSize: Int
    let layers: [LayerKind]
    let normEpsilon: Float
    let convolutionWidth: Int
    let slidingWindow: Int
    let sandwichNorm: Bool
    let rotations: [String: Rotation]

    enum CodingKeys: String, CodingKey {
      case hiddenSize = "hidden_size"
      case headCount = "num_attention_heads"
      case keyValueHeadCount = "num_key_value_heads"
      case headSize = "head_dim"
      case layers = "layer_types"
      case normEpsilon = "norm_eps"
      case convolutionWidth = "conv_L_cache"
      case slidingWindow = "sliding_window"
      case sandwichNorm = "use_sandwich_norm"
      case rotations = "rope_parameters"
    }

    func rotation(for kind: LayerKind) -> Rotation? { rotations[kind.rawValue] }
  }

  struct Vision: Decodable, Sendable {
    enum LayerKind: String, Decodable, Sendable {
      case convolution = "conv"
      case fullAttention = "full_attention"
    }

    let hiddenSize: Int
    let headCount: Int
    let keyValueHeadCount: Int
    let layers: [LayerKind]
    let normEpsilon: Float
    let patchSize: Int
    let frames: Int
    let merge: Int
    let channels: Int
    let kernel: Int
    let rotation: Rotation

    enum CodingKeys: String, CodingKey {
      case hiddenSize = "hidden_size"
      case headCount = "num_attention_heads"
      case keyValueHeadCount = "num_key_value_heads"
      case layers = "layer_types"
      case normEpsilon = "norm_eps"
      case patchSize = "patch_size"
      case frames = "temporal_patch_size"
      case merge = "spatial_merge_size"
      case channels = "in_channels"
      case kernel = "conv_kernel_size"
      case rotation = "rope_parameters"
    }
  }

  /// How the language model's weights are packed, when they are.
  struct Quantization: Decodable, Sendable {
    let groupSize: Int
    let bits: Int
    let mode: String?

    enum CodingKeys: String, CodingKey {
      case groupSize = "group_size"
      case bits, mode
    }
  }

  let modelType: String
  let text: Text
  let vision: Vision
  let attention: String
  let visionMaxPixels: Int
  let projectorEpsilon: Float
  let quantization: Quantization?

  enum CodingKeys: String, CodingKey {
    case modelType = "model_type"
    case text = "text_config"
    case vision = "vision_config"
    case attention = "d1_attention"
    case visionMaxPixels = "d1_vision_max_pixels"
    case projectorEpsilon = "projector_layer_norm_eps"
    case quantization
  }

  static func load(from directory: URL) throws -> D1Config {
    let config: D1Config
    do {
      config = try JSONDecoder().decode(
        D1Config.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
    } catch {
      throw EngineError.failed("The decision model's settings file is missing or not valid.")
    }
    // Only what this code was checked against is run; anything else would give wrong answers quietly.
    let known =
      config.modelType == "lfm3_vl" && config.attention == "set"
      && (config.quantization?.mode ?? "affine") == "affine"
      && config.text.headCount % config.text.keyValueHeadCount == 0
      && config.vision.headCount % config.vision.keyValueHeadCount == 0
    guard known else {
      throw EngineError.failed("This decision model is a kind the app cannot run yet.")
    }
    return config
  }
}

/// The checkpoint's temperature for yes/no answers, from `calibration.json`.
struct D1Calibration: Sendable {
  let yesNoTemperature: Double

  static func load(from directory: URL) -> D1Calibration {
    struct File: Decodable {
      let temperatures: [String: Double]
      let `default`: Double?
    }
    let url = directory.appendingPathComponent("calibration.json")
    guard let data = try? Data(contentsOf: url),
      let file = try? JSONDecoder().decode(File.self, from: data)
    else { return D1Calibration(yesNoTemperature: 1) }  // none shipped: answers are used as they are
    let temperature = file.temperatures["noul"] ?? file.default ?? 1
    return D1Calibration(yesNoTemperature: temperature > 0 ? temperature : 1)
  }

  /// P(yes) from the best score of each answer.
  func yesProbability(yes: Double, no: Double) -> Double {
    1 / (1 + exp((no - yes) / yesNoTemperature))
  }
}
