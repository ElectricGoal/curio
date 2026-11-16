import Foundation
import MLX

/// A checkpoint's tensors by name, with the few layer kinds LFM3 is built from.
///
/// Layers are functions over named weights rather than objects: the checkpoint
/// decides which are packed (quantized) and which are not, and this reads
/// either without the model code knowing.
struct D1Weights {
  let arrays: [String: MLXArray]
  let quantization: D1Config.Quantization?

  func array(_ name: String) throws -> MLXArray {
    guard let array = arrays[name] else {
      throw EngineError.failed("The decision model's files are incomplete (\(name) is missing).")
    }
    return array
  }

  /// `x` through the linear layer called `name`.
  func linear(_ name: String, _ x: MLXArray) throws -> MLXArray {
    let weight = try array(name + ".weight")
    var y: MLXArray
    if let scales = arrays[name + ".scales"] {
      y = quantizedMM(
        x, weight, scales: scales, biases: arrays[name + ".biases"], transpose: true,
        groupSize: quantization?.groupSize, bits: quantization?.bits)
    } else {
      y = matmul(x, weight.T)
    }
    if let bias = arrays[name + ".bias"] { y = y + bias }
    return y
  }

  /// Rows of the embedding table called `name`.
  func embedding(_ name: String, _ ids: [Int]) throws -> MLXArray {
    let weight = try array(name + ".weight")
    let rows = MLXArray(ids.map(Int32.init))
    guard let scales = arrays[name + ".scales"] else { return weight[rows] }
    return dequantized(
      weight[rows], scales: scales[rows], biases: arrays[name + ".biases"].map { $0[rows] },
      groupSize: quantization?.groupSize, bits: quantization?.bits)
  }

  func rmsNorm(_ name: String, _ x: MLXArray, epsilon: Float) throws -> MLXArray {
    MLXFast.rmsNorm(x, weight: try array(name + ".weight"), eps: epsilon)
  }
}

/// The forward pass of a d1 checkpoint: a vision tower, a projector into the
/// language model's space, and the LFM3 language model read under "set"
/// attention (every question sees the picture and itself, not the other questions).
///
/// Adapted for Swift from mlx-vlm's LFM3-VL and d1 models (Apache-2.0), which
/// follow the reference code shipped with the LiquidAI checkpoints.
struct D1Network {
  let config: D1Config
  let weights: D1Weights

  // MARK: - Shared pieces

  /// The gated feed-forward block both towers use.
  private func feedForward(_ prefix: String, _ x: MLXArray) throws -> MLXArray {
    let gate = try weights.linear(prefix + ".w1", x)
    return try weights.linear(prefix + ".w2", gate * sigmoid(gate) * weights.linear(prefix + ".w3", x))
  }

  /// Turns each pair (first half, second half) of the last axis by `angles`.
  private func rotated(_ x: MLXArray, cosine: MLXArray, sine: MLXArray) -> MLXArray {
    let halves = split(x, parts: 2, axis: -1)
    return x * cosine + concatenated([-halves[1], halves[0]], axis: -1) * sine
  }

  // MARK: - Vision

  /// The picture as tokens in the language model's space: one per block of patches.
  func features(of picture: D1Picture) throws -> MLXArray {
    let vision = config.vision
    let prefix = "vision_tower"
    let type = try weights.array("\(prefix).embedding_norm.weight").dtype
    let pixels = MLXArray(picture.patches, [picture.patchCount, picture.patches.count / picture.patchCount])
    var x = try weights.linear("\(prefix).patchifier", pixels.asType(type))
    x = try weights.rmsNorm("\(prefix).embedding_norm", x, epsilon: vision.normEpsilon)
    let (cosine, sine) = gridAngles(rows: picture.rows, columns: picture.columns)
    for (index, kind) in vision.layers.enumerated() {
      let layer = "\(prefix).layers.\(index)"
      let h = try weights.rmsNorm("\(layer).operator_norm", x, epsilon: vision.normEpsilon)
      switch kind {
      case .fullAttention:
        x = x + (try visionAttention("\(layer).self_attn", h, cosine: cosine, sine: sine))
      case .convolution:
        x = x + (try visionConvolution("\(layer).conv", h, rows: picture.rows, columns: picture.columns))
      }
      x = x + (try feedForward(
        "\(layer).feed_forward", weights.rmsNorm("\(layer).ffn_norm", x, epsilon: vision.normEpsilon)))
    }
    // The projector reads each merge × merge block of patches as one token.
    let projector = "multi_modal_projector"
    let normed = MLXFast.layerNorm(
      x, weight: try weights.array("\(projector).layer_norm.weight"),
      bias: try weights.array("\(projector).layer_norm.bias"), eps: config.projectorEpsilon)
    let blocks = normed.reshaped([-1, vision.hiddenSize * vision.merge * vision.merge])
    let hidden = try weights.linear("\(projector).linear_1", blocks)
    return try weights.linear("\(projector).linear_2", gelu(hidden))
  }

  private func gelu(_ x: MLXArray) -> MLXArray {
    x * (1 + erf(x / Float(2).squareRoot())) / 2
  }

  /// Rotation angles for every patch from its row and column, in block order.
  private func gridAngles(rows: Int, columns: Int) -> (cosine: MLXArray, sine: MLXArray) {
    let vision = config.vision
    let merge = vision.merge
    let spatial = vision.hiddenSize / vision.headCount / 2
    let frequencies = stride(from: 0, to: spatial, by: 2).map {
      powf(vision.rotation.theta, -Float($0) / Float(spatial))
    }
    var angles: [Float] = []
    angles.reserveCapacity(rows * columns * 2 * spatial)
    for blockRow in 0..<(rows / merge) {
      for blockColumn in 0..<(columns / merge) {
        for inRow in 0..<merge {
          for inColumn in 0..<merge {
            let row = Float(blockRow * merge + inRow)
            let column = Float(blockColumn * merge + inColumn)
            let own = frequencies.map { row * $0 } + frequencies.map { column * $0 }
            angles += own + own
          }
        }
      }
    }
    let array = MLXArray(angles, [rows * columns, 1, 2 * spatial])
    return (cos(array), sin(array))
  }

  private func visionAttention(_ prefix: String, _ x: MLXArray, cosine: MLXArray, sine: MLXArray)
    throws -> MLXArray
  {
    let vision = config.vision
    let count = x.dim(0)
    let headSize = vision.hiddenSize / vision.headCount
    let type = x.dtype
    var q = try weights.linear("\(prefix).q_proj", x).reshaped([count, vision.headCount, headSize])
    var k = try weights.linear("\(prefix).k_proj", x).reshaped([count, vision.keyValueHeadCount, headSize])
    let v = try weights.linear("\(prefix).v_proj", x).reshaped([count, vision.keyValueHeadCount, headSize])
    q = try weights.rmsNorm("\(prefix).q_layernorm", q, epsilon: vision.normEpsilon)
    k = try weights.rmsNorm("\(prefix).k_layernorm", k, epsilon: vision.normEpsilon)
    q = rotated(q.asType(.float32), cosine: cosine, sine: sine).asType(type)
    k = rotated(k.asType(.float32), cosine: cosine, sine: sine).asType(type)
    let out = MLXFast.scaledDotProductAttention(
      queries: q.transposed(1, 0, 2).expandedDimensions(axis: 0),
      keys: k.transposed(1, 0, 2).expandedDimensions(axis: 0),
      values: v.transposed(1, 0, 2).expandedDimensions(axis: 0),
      scale: 1 / Float(headSize).squareRoot(), mask: .none)
    return try weights.linear("\(prefix).out_proj", out[0].transposed(1, 0, 2).reshaped([count, -1]))
  }

  /// A gated 3 × 3 convolution over the picture, with the patches put back on their grid.
  private func visionConvolution(_ prefix: String, _ x: MLXArray, rows: Int, columns: Int) throws
    -> MLXArray
  {
    let merge = config.vision.merge
    let parts = split(try weights.linear("\(prefix).in_proj", x), parts: 3, axis: -1)
    let grid = (parts[0] * parts[2])
      .reshaped([rows / merge, columns / merge, merge, merge, -1])
      .transposed(0, 2, 1, 3, 4)
      .reshaped([1, rows, columns, -1])
    let weight = try weights.array("\(prefix).spatial_conv.weight")
    let convolved = conv2d(
      grid, weight, padding: IntOrPair(config.vision.kernel / 2), groups: config.vision.hiddenSize)
    let back = convolved
      .reshaped([rows / merge, merge, columns / merge, merge, -1])
      .transposed(0, 2, 1, 3, 4)
      .reshaped([rows * columns, -1])
    return try weights.linear("\(prefix).out_proj", parts[1] * back)
  }

  // MARK: - Language

  /// The final hidden state of every token of `row`, with the picture's
  /// `features` in place of its image tokens.
  func hidden(for row: D1Row, features: MLXArray, imageToken: Int) throws -> MLXArray {
    let text = config.text
    let prefix = "language_model.model"
    guard let first = row.ids.firstIndex(of: imageToken),
      let last = row.ids.lastIndex(of: imageToken), last - first + 1 == features.dim(0),
      row.ids[first...last].allSatisfy({ $0 == imageToken })
    else { throw EngineError.failed("The picture does not fit the prompt built for it.") }
    let table = "\(prefix).embed_tokens"
    let head = try weights.embedding(table, Array(row.ids[..<first]))
    let tail = try weights.embedding(table, Array(row.ids[(last + 1)...]))
    var h = concatenated([head, features.asType(head.dtype), tail], axis: 0).expandedDimensions(axis: 0)

    let length = row.ids.count
    let masks = D1Masks(row: row, window: text.slidingWindow)
    let positions = MLXArray((0..<length).map(Float.init))
    for (index, kind) in text.layers.enumerated() {
      let layer = "\(prefix).layers.\(index)"
      var o = try weights.rmsNorm("\(layer).operator_norm", h, epsilon: text.normEpsilon)
      switch kind {
      case .convolution:
        o = try shortConvolution("\(layer).conv", o)
      case .fullAttention, .slidingAttention:
        o = try attention(
          "\(layer).self_attn", o, kind: kind, positions: positions,
          mask: kind == .fullAttention ? masks.full : masks.sliding)
      }
      if text.sandwichNorm {
        o = try weights.rmsNorm("\(layer).post_operator_norm", o, epsilon: text.normEpsilon)
      }
      h = h + o
      var f = try feedForward(
        "\(layer).feed_forward", weights.rmsNorm("\(layer).ffn_norm", h, epsilon: text.normEpsilon))
      if text.sandwichNorm {
        f = try weights.rmsNorm("\(layer).post_ffn_norm", f, epsilon: text.normEpsilon)
      }
      h = h + f
    }
    return try weights.rmsNorm("\(prefix).embedding_norm", h, epsilon: text.normEpsilon)[0]
  }

  /// A gated convolution over the few tokens before each one.
  private func shortConvolution(_ prefix: String, _ x: MLXArray) throws -> MLXArray {
    let text = config.text
    let parts = split(try weights.linear("\(prefix).in_proj", x), parts: 3, axis: -1)
    let gated = padded(
      parts[0] * parts[2],
      widths: [IntOrPair(0), IntOrPair((text.convolutionWidth - 1, 0)), IntOrPair(0)])
    let convolved = conv1d(gated, try weights.array("\(prefix).conv.weight"), groups: text.hiddenSize)
    return try weights.linear("\(prefix).out_proj", parts[1] * convolved)
  }

  private func attention(
    _ prefix: String, _ x: MLXArray, kind: D1Config.Text.LayerKind, positions: MLXArray,
    mask: MLXFast.ScaledDotProductAttentionMaskMode
  ) throws -> MLXArray {
    let text = config.text
    let length = x.dim(1)
    let heads = text.headCount
    let keyValueHeads = text.keyValueHeadCount
    let size = text.headSize
    var q = try weights.linear("\(prefix).q_proj", x).reshaped([1, length, heads, size])
    var k = try weights.linear("\(prefix).k_proj", x).reshaped([1, length, keyValueHeads, size])
    let v = try weights.linear("\(prefix).v_proj", x)
      .reshaped([1, length, keyValueHeads, size]).transposed(0, 2, 1, 3)
    q = try weights.rmsNorm("\(prefix).q_norm", q, epsilon: text.normEpsilon).transposed(0, 2, 1, 3)
    k = try weights.rmsNorm("\(prefix).k_norm", k, epsilon: text.normEpsilon).transposed(0, 2, 1, 3)

    // Only part of each head may be rotated; the rest of its angles are zero.
    guard let rotation = text.rotation(for: kind) else {
      throw EngineError.failed("This decision model is a kind the app cannot run yet.")
    }
    let turning = Int(Float(size) * (rotation.partialFactor ?? 1)) / 2
    let frequencies = (0..<(size / 2)).map {
      $0 < turning ? powf(rotation.theta, -Float($0) * 2 / Float(size)) : 0
    }
    let half = positions.expandedDimensions(axis: -1) * MLXArray(frequencies)
    let angles = concatenated([half, half], axis: -1)
    let cosine = cos(angles).asType(q.dtype)
    let sine = sin(angles).asType(q.dtype)
    q = rotated(q, cosine: cosine, sine: sine)
    k = rotated(k, cosine: cosine, sine: sine)

    let out = MLXFast.scaledDotProductAttention(
      queries: q, keys: k, values: v, scale: 1 / Float(size).squareRoot(), mask: mask
    ).transposed(0, 2, 1, 3)
    let gate = sigmoid(try weights.linear("\(prefix).gate_proj", x)).expandedDimensions(axis: -1)
    return try weights.linear("\(prefix).o_proj", (out * gate).reshaped([1, length, -1]))
  }

  // MARK: - Reading the answers

  /// Scores of `tokens` at each of `slots`: one row per slot, one column per token.
  func scores(hidden: MLXArray, slots: [Int], tokens: [Int]) throws -> [[Float]] {
    let rows = hidden[MLXArray(slots.map(Int32.init))]
    let table = try weights.embedding("language_model.model.embed_tokens", tokens)
    let logits = matmul(rows, table.T).asType(.float32)
    let flat = logits.asArray(Float.self)
    return slots.indices.map { Array(flat[($0 * tokens.count)..<(($0 + 1) * tokens.count)]) }
  }
}

/// Who may read whom in one packed row.
struct D1Masks {
  /// Full attention: every token reads the state, the state reads everything,
  /// and a question reads itself — never another question.
  let full: MLXFast.ScaledDotProductAttentionMaskMode
  /// Sliding attention: each token reads the `window` tokens up to itself.
  let sliding: MLXFast.ScaledDotProductAttentionMaskMode

  init(row: D1Row, window: Int) {
    let length = row.ids.count
    full = .array(MLXArray(Self.fullValues(row), [length, length]))
    if length <= window {
      sliding = .causal
    } else {
      var values = [Bool](repeating: false, count: length * length)
      for reader in 0..<length {
        for read in max(0, reader - window + 1)...reader { values[reader * length + read] = true }
      }
      sliding = .array(MLXArray(values, [length, length]))
    }
  }

  static func fullValues(_ row: D1Row) -> [Bool] {
    let length = row.ids.count
    var values = [Bool](repeating: false, count: length * length)
    for reader in 0..<length {
      for read in 0..<length {
        values[reader * length + read] =
          reader < row.stateLength || read < row.stateLength || row.groups[reader] == row.groups[read]
      }
    }
    return values
  }
}
