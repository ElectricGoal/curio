import Foundation

/// CLIP's byte-pair-encoding tokenizer: turns a text query into the fixed-length
/// list of token ids the text encoder expects.
///
/// It follows the reference implementation step for step — the same cleaning,
/// the same word pattern, the same merge rules — because a tokenizer that is
/// merely similar produces embeddings that are merely similar.
public struct CLIPTokenizer: Sendable {
  private static let endOfWord = "</w>"
  /// The reference tokenizer's word pattern: contractions, runs of letters,
  /// single digits, and runs of anything else that is not whitespace.
  private static let wordPattern = try! NSRegularExpression(
    pattern: #"'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
    options: [.caseInsensitive])
  /// What smart punctuation becomes, as the reference's text fixer does.
  private static let straightened: [Character: Character] = [
    "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
    "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
  ]

  private let ranks: [Pair: Int]
  private let vocabulary: [String: Int32]
  /// Printable stand-ins for the 256 byte values, as the vocabulary spells them.
  private let byteSymbols: [String]
  private let contextLength: Int
  private let startToken: Int32
  private let endToken: Int32
  private let padToken: Int32

  private struct Pair: Hashable {
    let first: String
    let second: String
  }

  public init(mergesFile: URL, manifest: ModelManifest) throws {
    let text: String
    do {
      text = try String(contentsOf: mergesFile, encoding: .utf8)
    } catch {
      throw EngineError.failed("The model's tokenizer file could not be read.")
    }
    self.init(
      merges: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init),
      contextLength: manifest.contextLength, startToken: manifest.startToken,
      endToken: manifest.endToken, padToken: manifest.padToken)
  }

  public init(
    merges: [String], contextLength: Int, startToken: Int32, endToken: Int32, padToken: Int32
  ) {
    // Bytes that are printable keep their own character; the rest are mapped
    // to code points from 256 up, in byte order.
    var printable = Array(UInt32(33)...UInt32(126))
    printable += Array(UInt32(161)...UInt32(172))
    printable += Array(UInt32(174)...UInt32(255))
    var symbolForByte = [String](repeating: "", count: 256)
    var order: [String] = []
    for value in printable {
      let symbol = String(UnicodeScalar(value)!)
      symbolForByte[Int(value)] = symbol
      order.append(symbol)
    }
    var next: UInt32 = 256
    for byte in 0..<256 where symbolForByte[byte].isEmpty {
      let symbol = String(UnicodeScalar(next)!)
      symbolForByte[byte] = symbol
      order.append(symbol)
      next += 1
    }
    byteSymbols = symbolForByte

    // Ids follow the reference vocabulary: the symbols, the symbols ending a
    // word, one entry per merge rule, then the start and end markers.
    var vocabulary: [String: Int32] = [:]
    for (index, symbol) in order.enumerated() {
      vocabulary[symbol] = Int32(index)
      vocabulary[symbol + Self.endOfWord] = Int32(index + order.count)
    }
    var ranks: [Pair: Int] = [:]
    var id = Int32(order.count * 2)
    for (rank, line) in merges.enumerated() {
      let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      ranks[Pair(first: parts[0], second: parts[1])] = rank
      vocabulary[parts[0] + parts[1]] = id
      id += 1
    }
    self.ranks = ranks
    self.vocabulary = vocabulary
    self.contextLength = contextLength
    self.startToken = startToken
    self.endToken = endToken
    self.padToken = padToken
  }

  /// Token ids for `text`: start marker, the text, end marker, then padding.
  /// Text too long for the model is cut, keeping the end marker.
  public func tokenize(_ text: String) -> [Int32] {
    var tokens = [startToken] + encode(text) + [endToken]
    if tokens.count > contextLength {
      tokens = Array(tokens.prefix(contextLength))
      tokens[contextLength - 1] = endToken
    }
    return tokens + [Int32](repeating: padToken, count: contextLength - tokens.count)
  }

  func encode(_ text: String) -> [Int32] {
    let cleaned = Self.clean(text)
    let whole = NSRange(cleaned.startIndex..., in: cleaned)
    var ids: [Int32] = []
    for match in Self.wordPattern.matches(in: cleaned, range: whole) {
      guard let range = Range(match.range, in: cleaned) else { continue }
      let symbols = cleaned[range].utf8.map { byteSymbols[Int($0)] }
      for piece in merge(symbols) {
        if let id = vocabulary[piece] { ids.append(id) }
      }
    }
    return ids
  }

  /// Normalises text the way the reference does before splitting it into words.
  static func clean(_ text: String) -> String {
    let composed = text.precomposedStringWithCanonicalMapping
    let straight = String(composed.map { straightened[$0] ?? $0 })
    let halfWidth = straight.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? straight
    return halfWidth.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
  }

  /// Applies the merge rules to one word, best-ranked pair first.
  private func merge(_ symbols: [String]) -> [String] {
    guard var word = Optional(symbols), !word.isEmpty else { return [] }
    word[word.count - 1] += Self.endOfWord
    while word.count > 1 {
      var best: (pair: Pair, rank: Int)?
      for index in 0..<(word.count - 1) {
        let pair = Pair(first: word[index], second: word[index + 1])
        if let rank = ranks[pair], rank < (best?.rank ?? .max) { best = (pair, rank) }
      }
      guard let chosen = best?.pair else { break }
      var merged: [String] = []
      merged.reserveCapacity(word.count)
      var index = 0
      while index < word.count {
        if index < word.count - 1, word[index] == chosen.first, word[index + 1] == chosen.second {
          merged.append(chosen.first + chosen.second)
          index += 2
        } else {
          merged.append(word[index])
          index += 1
        }
      }
      word = merged
    }
    return word
  }
}
