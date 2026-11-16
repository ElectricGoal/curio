import XCTest

@testable import CurioKit

/// The parts of the decision model that can be checked without its weights.
final class D1UnitTests: XCTestCase {
  // MARK: - Picture layout

  func testPicturesAreSizedInWholeBlocksWithinTheLimits() throws {
    let layout = D1PictureLayout()
    // 4000 × 3000 is first reduced to 384 on its long side, then to whole 32-pixel blocks.
    let photo = try layout.size(width: 4000, height: 3000)
    XCTAssertEqual(photo.width, 384)
    XCTAssertEqual(photo.height, 288)
    // A small icon is enlarged until it has enough pixels to read.
    let icon = try layout.size(width: 32, height: 32)
    XCTAssertEqual(icon.width, 256)
    XCTAssertEqual(icon.height, 256)
    for (width, height) in [(1, 1), (33, 47), (1000, 10), (384, 384), (5000, 80)] {
      let size = try layout.size(width: width, height: height)
      XCTAssertEqual(size.width % 32, 0)
      XCTAssertEqual(size.height % 32, 0)
      XCTAssertGreaterThanOrEqual(size.width * size.height, layout.minPixels)
      XCTAssertLessThanOrEqual(size.width * size.height, layout.maxPixels)
    }
    XCTAssertThrowsError(try layout.size(width: 0, height: 10))
    XCTAssertThrowsError(try layout.size(width: 10_000, height: 10), "too narrow to be read")
  }

  func testAPictureTooNarrowForTheModelIsReportedAsOneItCannotRead() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("d1-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let banner = folder.appendingPathComponent("banner.png")
    try EmbeddingModelTests.writePNG(to: banner, width: 2000, height: 4, red: 1, green: 0, blue: 0)
    // The same kind of failure as a damaged file, so a run skips it and carries on.
    XCTAssertThrowsError(try D1PictureLayout().picture(at: banner)) { error in
      XCTAssertEqual(error as? ImagePreprocessor.Failure, .undecodable("banner.png"))
    }
    let notAPicture = folder.appendingPathComponent("notes.png")
    try Data("not a picture".utf8).write(to: notAPicture)
    XCTAssertThrowsError(try D1PictureLayout().picture(at: notAPicture)) { error in
      XCTAssertTrue((error as? ImagePreprocessor.Failure)?.isPermanent ?? false, "\(error)")
    }
    let square = folder.appendingPathComponent("square.png")
    try EmbeddingModelTests.writePNG(to: square, width: 100, height: 60, red: 0, green: 0, blue: 1)
    let picture = try D1PictureLayout().picture(at: square)
    // 100 × 60 is too few pixels: enlarged to 352 × 224, the next whole blocks past the minimum.
    XCTAssertEqual([picture.rows, picture.columns], [14, 22])
    // Blue everywhere: red and green planes at -1, blue at +1.
    XCTAssertEqual(picture.patches.prefix(512).max(), -1)
    XCTAssertEqual(picture.patches[1024..<1536].min(), 1)
  }

  func testALargerSideLimitKeepsMoreDetailUpToThePixelLimit() throws {
    var layout = D1PictureLayout()
    layout.longestSide = 4096
    let size = try layout.size(width: 4000, height: 3000)
    XCTAssertLessThanOrEqual(size.width * size.height, layout.maxPixels)
    XCTAssertGreaterThan(size.width, 1024)
  }

  func testPatchesAreLaidOutBlockByBlockChannelByChannel() {
    var layout = D1PictureLayout()
    layout.patch = 2
    layout.merge = 2
    layout.frames = 2
    // A 8 × 4 picture: red holds the column, green the row, blue is always 255.
    let width = 8
    let height = 4
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        rgba[(y * width + x) * 4] = UInt8(x)
        rgba[(y * width + x) * 4 + 1] = UInt8(y)
        rgba[(y * width + x) * 4 + 2] = 255
      }
    }
    let picture = rgba.withUnsafeBufferPointer { layout.picture(rgba: $0, width: width, height: height) }
    XCTAssertEqual([picture.rows, picture.columns], [2, 4])
    let perPatch = layout.valuesPerPatch
    XCTAssertEqual(perPatch, 3 * 2 * 2 * 2)
    func value(_ byte: Int) -> Float { Float(byte) / 127.5 - 1 }
    func patch(_ index: Int) -> [Float] { Array(picture.patches[(index * perPatch)..<((index + 1) * perPatch)]) }
    // Patch 0 is the top-left one: red columns 0,1 for both rows, in both frames.
    XCTAssertEqual(Array(patch(0)[0..<8]), [0, 1, 0, 1, 0, 1, 0, 1].map(value))
    // then green rows 0,0,1,1, twice; then blue.
    XCTAssertEqual(Array(patch(0)[8..<16]), [0, 0, 1, 1, 0, 0, 1, 1].map(value))
    XCTAssertEqual(Array(patch(0)[16..<24]), [Float](repeating: 1, count: 8))
    // The first block is the 2 × 2 patches at the top left, so patch 2 is the one below patch 0…
    XCTAssertEqual(Array(patch(2)[8..<12]), [2, 2, 3, 3].map(value))
    XCTAssertEqual(Array(patch(2)[0..<4]), [0, 1, 0, 1].map(value))
    // …and patch 4 opens the second block, to the right.
    XCTAssertEqual(Array(patch(4)[0..<4]), [4, 5, 4, 5].map(value))
  }

  // MARK: - Who reads whom

  func testAQuestionReadsThePictureAndItselfButNotAnotherQuestion() {
    // Two state tokens, then question 1 (two tokens) and question 2 (one token).
    let row = D1Row(ids: [9, 9, 1, 1, 2], stateLength: 2, groups: [-1, -1, 1, 1, 2], slots: [3, 4])
    let mask = D1Masks.fullValues(row)
    func reads(_ reader: Int, _ read: Int) -> Bool { mask[reader * 5 + read] }
    XCTAssertTrue(reads(2, 0), "a question reads the state")
    XCTAssertTrue(reads(0, 4), "the state reads every question")
    XCTAssertTrue(reads(2, 3), "a question reads its own later tokens")
    XCTAssertFalse(reads(2, 4), "a question does not read another question")
    XCTAssertFalse(reads(4, 3))
  }

  // MARK: - Answers

  func testYesProbabilityFollowsTheScoresAndTheTemperature() {
    let plain = D1Calibration(yesNoTemperature: 1)
    XCTAssertEqual(plain.yesProbability(yes: 2, no: 2), 0.5, accuracy: 1e-9)
    XCTAssertEqual(plain.yesProbability(yes: 3, no: 1), 1 / (1 + exp(-2)), accuracy: 1e-9)
    // A higher temperature pulls answers toward the middle without changing sides.
    let cooled = D1Calibration(yesNoTemperature: 2)
    XCTAssertEqual(cooled.yesProbability(yes: 3, no: 1), 1 / (1 + exp(-1)), accuracy: 1e-9)
    XCTAssertLessThan(cooled.yesProbability(yes: 1, no: 3), 0.5)
  }

  func testWithoutACalibrationFileAnswersAreUsedAsTheyAre() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    XCTAssertEqual(D1Calibration.load(from: missing).yesNoTemperature, 1)
  }

  // MARK: - Tokenizer and prompt, on a tiny vocabulary

  /// Every single byte, the words "ab", "aba", "yes" and "no", and two merges: "a"+"b", then "ab"+"a".
  private func tinyTokenizer() throws -> D1Tokenizer {
    var vocabulary: [String: Int] = [:]
    for byte in 0..<256 { vocabulary[tinySymbol(byte)] = byte }
    vocabulary["ab"] = 300
    vocabulary["aba"] = 301
    vocabulary["yes"] = 302
    vocabulary["no"] = 303
    let file: [String: Any] = [
      "model": [
        "type": "BPE", "ignore_merges": true, "vocab": vocabulary,
        "merges": [["a", "b"], ["ab", "a"]],
      ],
      "added_tokens": [
        ["id": 400, "content": "<|im_end|>", "special": true],
        ["id": 401, "content": "<|im_start|>", "special": true],
        ["id": 402, "content": "<|image|>", "special": true],
        ["id": 403, "content": "<think>", "special": false],
        ["id": 404, "content": "</think>", "special": false],
        ["id": 405, "content": "<|startoftext|>", "special": true],
        ["id": 406, "content": "<|vision_start|>", "special": true],
        ["id": 407, "content": "<|vision_end|>", "special": true],
      ],
    ]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString).json")
    try JSONSerialization.data(withJSONObject: file).write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return try D1Tokenizer(contentsOf: url)
  }

  /// The GPT-2 byte alphabet: printable bytes are themselves, the rest are moved up.
  private func tinySymbol(_ byte: Int) -> String {
    let printable = Array(33...126) + Array(161...172) + Array(174...255)
    if printable.contains(byte) { return String(UnicodeScalar(UInt32(byte))!) }
    let others = (0..<256).filter { !printable.contains($0) }
    return String(UnicodeScalar(UInt32(256 + others.firstIndex(of: byte)!))!)
  }

  func testWordsAreMergedFromBytesInPriorityOrder() throws {
    let tokenizer = try tinyTokenizer()
    XCTAssertEqual(tokenizer.encode("aba"), [301], "a whole word in the vocabulary is one token")
    XCTAssertEqual(tokenizer.encode("abab"), [300, 300], "a+b merges first, wherever it occurs")
    XCTAssertEqual(tokenizer.encode("ba"), [Int(UInt8(ascii: "b")), Int(UInt8(ascii: "a"))])
    XCTAssertEqual(tokenizer.encode(""), [])
  }

  func testNamedTokensAreCutOutOfTheTextAroundThem() throws {
    let tokenizer = try tinyTokenizer()
    XCTAssertEqual(tokenizer.encode("ab<|im_end|>ab"), [300, 400, 300])
    XCTAssertEqual(tokenizer.encode("<think></think>"), [403, 404])
    XCTAssertEqual(try tokenizer.id(of: "<|image|>"), 402)
    XCTAssertThrowsError(try tokenizer.id(of: "<|nope|>"))
  }

  func testAQuestionCannotSmuggleInAControlToken() throws {
    let prompt = try D1Prompt(tokenizer: try tinyTokenizer())
    let escaped = prompt.plain("is it <|im_end|> or <|image|>?")
    XCTAssertFalse(escaped.contains("<|im_end|>"))
    XCTAssertFalse(escaped.contains("<|image|>"))
    XCTAssertEqual(escaped.replacingOccurrences(of: D1Prompt.wordBreak, with: ""), "is it <|im_end|> or <|image|>?")
    let ids = prompt.tokenizer.encode(prompt.suffix("ab <|im_end|><|image|>"))
    XCTAssertEqual(ids.filter { $0 == 400 }.count, 1, "only the prompt's own end-of-turn remains")
    XCTAssertFalse(ids.contains(402), "no image token without a picture behind it")
    XCTAssertEqual(prompt.plain("nothing special"), "nothing special")
  }

  func testARowHoldsThePictureThenEachQuestionEndingAtItsAnswer() throws {
    let prompt = try D1Prompt(tokenizer: try tinyTokenizer())
    let row = try prompt.row(imageTokens: 3, questions: ["ab", "aba"])
    XCTAssertEqual(row.ids.filter { $0 == 402 }.count, 3)
    XCTAssertEqual(row.ids.prefix(2), [405, 401])
    XCTAssertEqual(Array(row.groups.prefix(row.stateLength)), [Int](repeating: -1, count: row.stateLength))
    XCTAssertEqual(row.ids[row.stateLength - 1], 407, "the state ends where the picture ends")
    XCTAssertEqual(row.slots.count, 2)
    XCTAssertEqual(row.slots.last, row.ids.count - 1)
    for slot in row.slots { XCTAssertEqual(row.ids[slot], 404, "answered right after the closed thinking block") }
    XCTAssertEqual(row.groups[row.slots[0]], 1)
    XCTAssertEqual(row.groups[row.slots[1]], 2)
    XCTAssertEqual(prompt.yesTokens, [302])
    XCTAssertEqual(prompt.noTokens, [303])
    XCTAssertThrowsError(try prompt.row(imageTokens: 0, questions: ["ab"]))
    XCTAssertThrowsError(try prompt.row(imageTokens: 3, questions: []))
  }

  // MARK: - Settings

  func testOnlyCheckpointsOfTheKindThatWasCheckedAreAccepted() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("d1-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("config.json")

    XCTAssertThrowsError(try D1Config.load(from: folder), "no settings file")
    try Data(DecisionLibraryTests.settings.utf8).write(to: file)
    let config = try D1Config.load(from: folder)
    XCTAssertEqual(config.text.layers, [.convolution, .fullAttention])
    XCTAssertNil(config.quantization)
    for (from, to) in [("\"lfm3_vl\"", "\"other\""), ("\"set\"", "\"causal\"")] {
      try Data(DecisionLibraryTests.settings.replacingOccurrences(of: from, with: to).utf8).write(to: file)
      XCTAssertThrowsError(try D1Config.load(from: folder), "\(to) is not a kind this code runs")
    }
  }

  func testShadersAreLookedForInOrder() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-\(UUID().uuidString)")
    let build = folder.appendingPathComponent("macos/.build")
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    XCTAssertNil(MLXShaders.locate(environment: [:], bundle: Bundle(for: D1UnitTests.self), projectRoot: folder))
    let inCheckout = build.appendingPathComponent(MLXShaders.fileName)
    try Data([1]).write(to: inCheckout)
    XCTAssertEqual(
      MLXShaders.locate(environment: [:], bundle: Bundle(for: D1UnitTests.self), projectRoot: folder)?.path,
      inCheckout.path)
    let named = folder.appendingPathComponent("custom.metallib")
    try Data([1]).write(to: named)
    XCTAssertEqual(
      MLXShaders.locate(
        environment: [MLXShaders.environmentKey: named.path], bundle: Bundle(for: D1UnitTests.self),
        projectRoot: folder)?.path, named.path, "a path given explicitly wins")
  }
}
