import Foundation

/// The byte-pair tokenizer of Liquid's LFM3 models, read from a checkpoint's
/// `tokenizer.json`.
///
/// Text is cut around the checkpoint's named tokens (`<|im_end|>`, `<|image|>`…),
/// each stretch between them is split into words by the checkpoint's pattern,
/// and each word is merged from its bytes by the checkpoint's merge rules.
struct D1Tokenizer: Sendable {
  /// A token with a name of its own, matched in text before anything else.
  struct NamedToken: Sendable {
    let text: String
    let id: Int
    /// Control tokens; text from the user must never turn into one (`D1Prompt.plain`).
    let isSpecial: Bool
  }

  /// The split the checkpoint was trained with. `\p{White_Space}` stands in for
  /// `\s`, whose meaning differs between regular-expression engines.
  private static let wordPattern =
    #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\p{White_Space}\p{L}\p{N}]+[\r\n]*|\p{White_Space}*[\r\n]+|\p{White_Space}+(?!\P{White_Space})|\p{White_Space}+"#

  /// How each byte is written in the vocabulary (the GPT-2 byte alphabet).
  private static let byteSymbols: [String] = {
    var printable = Array(33...126) + Array(161...172) + Array(174...255)
    var symbols = [String](repeating: "", count: 256)
    var next = 256
    for byte in 0..<256 {
      if printable.contains(byte) {
        symbols[byte] = String(UnicodeScalar(UInt32(byte))!)
      } else {
        symbols[byte] = String(UnicodeScalar(UInt32(next))!)
        next += 1
      }
    }
    return symbols
  }()

  private let vocabulary: [String: Int]
  /// Merge priority of a pair, keyed "left right"; lower merges first.
  private let ranks: [String: Int]
  /// Whole words in the vocabulary skip merging, as the checkpoint asks.
  private let prefersWholeWords: Bool
  /// Longest first, so the longest name wins where several start at one place.
  let namedTokens: [NamedToken]
  private let words: NSRegularExpression

  init(contentsOf url: URL) throws {
    let invalid = EngineError.failed("The model's tokenizer file is not valid.")
    guard
      let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
      let model = root["model"] as? [String: Any], model["type"] as? String == "BPE",
      let vocabulary = model["vocab"] as? [String: Int], !vocabulary.isEmpty,
      let merges = model["merges"] as? [Any]
    else { throw invalid }
    var ranks: [String: Int] = [:]
    ranks.reserveCapacity(merges.count)
    for (rank, merge) in merges.enumerated() {
      // Written as ["left", "right"] by newer files and "left right" by older ones.
      if let pair = merge as? [String], pair.count == 2 {
        ranks[pair[0] + " " + pair[1]] = rank
      } else if let pair = merge as? String {
        ranks[pair] = rank
      } else {
        throw invalid
      }
    }
    let added = (root["added_tokens"] as? [[String: Any]]) ?? []
    let named = added.compactMap { entry -> NamedToken? in
      guard let text = entry["content"] as? String, let id = entry["id"] as? Int, !text.isEmpty
      else { return nil }
      return NamedToken(text: text, id: id, isSpecial: entry["special"] as? Bool ?? false)
    }
    self.vocabulary = vocabulary
    self.ranks = ranks
    prefersWholeWords = model["ignore_merges"] as? Bool ?? false
    namedTokens = named.sorted { $0.text.count > $1.text.count }
    words = try NSRegularExpression(pattern: Self.wordPattern)
  }

  /// The id of a named token such as `<|image|>`.
  func id(of name: String) throws -> Int {
    guard let token = namedTokens.first(where: { $0.text == name }) else {
      throw EngineError.failed("The model's tokenizer has no \(name) token.")
    }
    return token.id
  }

  func encode(_ text: String) -> [Int] {
    var ids: [Int] = []
    var plain = ""
    var rest = Substring(text)
    while let first = rest.first {
      // Every named token opens with "<", so most characters need no lookup.
      if first == "<", let token = namedTokens.first(where: { rest.hasPrefix($0.text) }) {
        ids += encodePlain(plain)
        plain = ""
        ids.append(token.id)
        rest = rest.dropFirst(token.text.count)
      } else {
        plain.append(first)
        rest = rest.dropFirst()
      }
    }
    return ids + encodePlain(plain)
  }

  /// Text with no named token in it.
  private func encodePlain(_ text: String) -> [Int] {
    guard !text.isEmpty else { return [] }
    let whole = text as NSString
    var ids: [Int] = []
    var covered = 0
    let all = NSRange(location: 0, length: whole.length)
    for match in words.matches(in: text, range: all) where match.range.length > 0 {
      // Anything the pattern steps over is still part of the text.
      if match.range.location > covered {
        ids += encodeWord(
          whole.substring(with: NSRange(location: covered, length: match.range.location - covered)))
      }
      ids += encodeWord(whole.substring(with: match.range))
      covered = match.range.location + match.range.length
    }
    if covered < whole.length { ids += encodeWord(whole.substring(from: covered)) }
    return ids
  }

  private func encodeWord(_ word: String) -> [Int] {
    var symbols = word.utf8.map { Self.byteSymbols[Int($0)] }
    if prefersWholeWords, let id = vocabulary[symbols.joined()] { return [id] }
    while symbols.count > 1 {
      var best: (rank: Int, index: Int)?
      for index in 0..<(symbols.count - 1) {
        if let rank = ranks[symbols[index] + " " + symbols[index + 1]], rank < best?.rank ?? .max {
          best = (rank, index)
        }
      }
      guard let best else { break }
      // Merge every occurrence of the winning pair, left to right.
      let left = symbols[best.index]
      let right = symbols[best.index + 1]
      var merged: [String] = []
      merged.reserveCapacity(symbols.count)
      var index = 0
      while index < symbols.count {
        if index < symbols.count - 1, symbols[index] == left, symbols[index + 1] == right {
          merged.append(left + right)
          index += 2
        } else {
          merged.append(symbols[index])
          index += 1
        }
      }
      symbols = merged
    }
    // Every single byte is in the vocabulary, so nothing is dropped here.
    return symbols.compactMap { vocabulary[$0] }
  }
}
