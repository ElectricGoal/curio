#if canImport(CoreAI)
  import CoreAI
  import Foundation

  /// The same d1 checkpoint as `D1DecisionModel`, run by Apple's Core AI
  /// (macOS 27) instead of MLX. Experimental: built to compare the two runtimes.
  ///
  /// The network comes from scripts/d1_coreai/export.py, which traces it for one
  /// picture grid and one prompt length (`geometry.json` beside the model). The
  /// picture layout, prompt, masks and calibration are the app's own, shared with
  /// the MLX model, so only the runtime differs.
  @available(macOS 27.0, *)
  public actor CoreAIDecisionModel: DecisionModel {
    struct Geometry: Decodable {
      let rows: Int
      let columns: Int
      let length: Int
    }

    public nonisolated let alias: String
    let function: InferenceFunction
    let prompt: D1Prompt
    let layout: D1PictureLayout
    let calibration: D1Calibration
    let geometry: Geometry
    let window: Int
    let merge: Int

    private init(
      alias: String, function: InferenceFunction, prompt: D1Prompt, layout: D1PictureLayout,
      calibration: D1Calibration, geometry: Geometry, window: Int, merge: Int
    ) {
      self.alias = alias
      self.function = function
      self.prompt = prompt
      self.layout = layout
      self.calibration = calibration
      self.geometry = geometry
      self.window = window
      self.merge = merge
    }

    /// Loads `asset` (an exported .aimodel, with `geometry.json` beside it); the
    /// tokenizer, settings and calibration come from the MLX checkpoint in `checkpoint`.
    public static func load(alias: String, asset: URL, checkpoint: URL, longestSide: Int = 384)
      async throws -> CoreAIDecisionModel
    {
      let model = try await AIModel(contentsOf: asset)
      guard let function = try model.loadFunction(named: "main") else {
        throw EngineError.failed("The Core AI model has no main function.")
      }
      let geometry = try JSONDecoder().decode(
        Geometry.self,
        from: Data(contentsOf: asset.deletingLastPathComponent().appendingPathComponent("geometry.json")))
      let config = try D1Config.load(from: checkpoint)
      let tokenizer = try D1Tokenizer(
        contentsOf: checkpoint.appendingPathComponent(D1DecisionModel.tokenizerFile))
      var layout = D1PictureLayout()
      layout.patch = config.vision.patchSize
      layout.merge = config.vision.merge
      layout.frames = config.vision.frames
      layout.channels = config.vision.channels
      layout.maxPixels = config.visionMaxPixels
      layout.longestSide = longestSide
      return CoreAIDecisionModel(
        alias: alias, function: function, prompt: try D1Prompt(tokenizer: tokenizer), layout: layout,
        calibration: D1Calibration.load(from: checkpoint), geometry: geometry,
        window: config.text.slidingWindow, merge: config.vision.merge)
    }

    public func decide(image: URL, questions: [String]) async throws -> [Double] {
      let picture = try layout.picture(at: image)
      guard picture.rows == geometry.rows, picture.columns == geometry.columns else {
        throw EngineError.failed(
          "This Core AI model reads \(geometry.rows)×\(geometry.columns)-patch pictures; this one is \(picture.rows)×\(picture.columns).")
      }
      let patches = NDArray(
        scalars: picture.patches.map(Float16.init),
        shape: [picture.patchCount, picture.patches.count / picture.patchCount])
      var answers: [Double] = []
      // One question per pass: the traced row holds the picture and one question.
      for question in questions {
        let row = try prompt.row(imageTokens: picture.patchCount / (merge * merge), questions: [question])
        answers.append(try await answer(row: row, patches: patches))
      }
      return answers
    }

    /// Runs one row, padded to the traced length with tokens no one reads.
    private func answer(row: D1Row, patches: NDArray) async throws -> Double {
      let real = row.ids.count
      let length = geometry.length
      guard real <= length else {
        throw EngineError.failed("This question is too long for the Core AI model (\(real) > \(length) tokens).")
      }
      let full = D1Masks.fullValues(row)
      var fullMask = [Float16](repeating: -.infinity, count: length * length)
      var slidingMask = fullMask
      for reader in 0..<length {
        guard reader < real else {
          // A padding token reads only itself, so its attention stays defined.
          fullMask[reader * length + reader] = 0
          slidingMask[reader * length + reader] = 0
          continue
        }
        for read in 0..<real where full[reader * real + read] { fullMask[reader * length + read] = 0 }
        for read in max(0, reader - window + 1)...reader { slidingMask[reader * length + read] = 0 }
      }
      let ids = row.ids.map(Int32.init) + [Int32](repeating: Int32(row.ids[0]), count: length - real)
      let tokens = (prompt.yesTokens + prompt.noTokens).map(Int32.init)
      var outputs = try await function.run(inputs: [
        "patches": patches,
        "ids": NDArray(scalars: ids, shape: [length]),
        "full_mask": NDArray(scalars: fullMask, shape: [1, 1, length, length]),
        "sliding_mask": NDArray(scalars: slidingMask, shape: [1, 1, length, length]),
        "slots": NDArray(scalars: row.slots.map(Int32.init), shape: [row.slots.count]),
        "tokens": NDArray(scalars: tokens, shape: [tokens.count]),
      ])
      guard let scores = outputs.remove("scores")?.ndArray else {
        throw EngineError.failed("The Core AI model gave no scores.")
      }
      let values = scores.view(as: Float.self).withUnsafePointer { pointer, _, _ in
        Array(UnsafeBufferPointer(start: pointer, count: tokens.count))
      }
      let yes = values[..<prompt.yesTokens.count].max() ?? 0
      let no = values[prompt.yesTokens.count...].max() ?? 0
      return calibration.yesProbability(yes: Double(yes), no: Double(no))
    }
  }
#endif
