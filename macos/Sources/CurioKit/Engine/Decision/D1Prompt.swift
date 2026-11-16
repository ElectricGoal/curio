import Foundation

/// What a d1 model reads for one picture and a set of yes/no questions.
///
/// The picture is "the state"; every question follows it in the same row. Each
/// question is answered at its last token, so nothing is generated.
struct D1Row: Equatable, Sendable {
  /// Token ids, with `imageToken` wherever a piece of the picture goes.
  let ids: [Int]
  /// How many leading tokens belong to the state, shared by all questions.
  let stateLength: Int
  /// Which question each token belongs to: 1, 2, … or -1 for the state.
  let groups: [Int]
  /// Where each question is answered: the index of its last token.
  let slots: [Int]
}

/// Builds d1 prompts the way the checkpoint was trained to read them.
///
/// Adapted from the `system_one` prompt code shipped with the LiquidAI d1
/// checkpoints (LFM Open License v1.0), for the one case this app uses: a
/// picture with no other state, and yes/no questions.
struct D1Prompt: Sendable {
  static let start = "<|startoftext|><|im_start|>user\n"
  static let visionStart = "<|vision_start|>"
  static let visionEnd = "<|vision_end|>"
  static let imageToken = "<|image|>"
  static let instruction = "\n\nReply with yes or no only."
  /// The checkpoint's chat template closes the reasoning block before a direct answer.
  static let answerOpening = "<|im_end|>\n<|im_start|>assistant\n<think></think>"
  static let yesForms = ["yes", "Yes", "YES"]
  static let noForms = ["no", "No", "NO"]
  /// A zero-width space: put inside a control token's name, the name reads the
  /// same and is no longer the token.
  static let wordBreak = "\u{200B}"

  let tokenizer: D1Tokenizer
  let imageTokenID: Int
  /// Tokens scored for "yes" and for "no"; each answer takes its best form.
  let yesTokens: [Int]
  let noTokens: [Int]
  private let controlNames: [String]

  init(tokenizer: D1Tokenizer) throws {
    self.tokenizer = tokenizer
    imageTokenID = try tokenizer.id(of: Self.imageToken)
    let single = { (forms: [String]) in
      forms.map(tokenizer.encode).filter { $0.count == 1 }.map { $0[0] }
    }
    yesTokens = single(Self.yesForms)
    noTokens = single(Self.noForms)
    guard !yesTokens.isEmpty, !noTokens.isEmpty else {
      throw EngineError.failed("The model's tokenizer has no single token for yes or no.")
    }
    controlNames = tokenizer.namedTokens
      .filter { $0.isSpecial && $0.text.count > 1 && !$0.text.contains(Self.wordBreak) }
      .map(\.text)
  }

  /// The question as the user's own text: no control token survives in it.
  func plain(_ text: String) -> String {
    var text = text
    var changed = true
    // Again after each pass, for a name that overlapped the one just broken.
    while changed {
      changed = false
      var result = ""
      var rest = Substring(text)
      while let first = rest.first {
        if first == "<", let name = controlNames.first(where: { rest.hasPrefix($0) }) {
          result += String(first) + Self.wordBreak + name.dropFirst()
          rest = rest.dropFirst(name.count)
          changed = true
        } else {
          result.append(first)
          rest = rest.dropFirst()
        }
      }
      text = result
    }
    return text
  }

  /// A question and the opening of the answer, up to where the answer is read.
  func suffix(_ question: String) -> String {
    plain(question + Self.instruction) + Self.answerOpening
  }

  /// One row for a picture of `imageTokens` pieces and its questions.
  func row(imageTokens: Int, questions: [String]) throws -> D1Row {
    guard imageTokens > 0, !questions.isEmpty else {
      throw EngineError.failed("A decision needs a picture and at least one question.")
    }
    let state =
      tokenizer.encode(Self.start + Self.visionStart)
      + [Int](repeating: imageTokenID, count: imageTokens)
      + tokenizer.encode(Self.visionEnd)
    var ids = state
    var groups = [Int](repeating: -1, count: state.count)
    var slots: [Int] = []
    for (index, question) in questions.enumerated() {
      let own = tokenizer.encode(suffix(question))
      ids += own
      groups += [Int](repeating: index + 1, count: own.count)
      slots.append(ids.count - 1)
    }
    return D1Row(ids: ids, stateLength: state.count, groups: groups, slots: slots)
  }
}
