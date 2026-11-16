import XCTest

@testable import CurioKit

final class CLIPTokenizerTests: XCTestCase {
  func testMatchesTheReferenceTokenizerForEveryCase() throws {
    for alias in ModelFixtures.aliases {
      let tokenizer = try ModelFixtures.tokenizer(alias)
      let cases = try ModelFixtures.reference(alias).tokenizer
      XCTAssertGreaterThan(cases.count, 10)
      for example in cases {
        XCTAssertEqual(
          tokenizer.tokenize(example.text), example.tokens,
          "\(alias): “\(example.text.prefix(40))”")
      }
    }
  }

  func testOutputIsAlwaysExactlyTheContextLength() throws {
    let tokenizer = try ModelFixtures.tokenizer("mobileclip-s4")
    for text in ["", "a", String(repeating: "very long query ", count: 200)] {
      let tokens = tokenizer.tokenize(text)
      XCTAssertEqual(tokens.count, 77)
      XCTAssertEqual(tokens.first, 49406)
      XCTAssertTrue(tokens.contains(49407), "the end marker survives truncation")
    }
  }

  func testTextIsCleanedBeforeTokenizing() throws {
    let tokenizer = try ModelFixtures.tokenizer("mobileclip-s4")
    // Case, surrounding and repeated whitespace do not change the meaning.
    XCTAssertEqual(tokenizer.tokenize("  A   Quiet\tBEACH \n"), tokenizer.tokenize("a quiet beach"))
    // macOS types smart quotes; the model was trained on straight ones.
    XCTAssertEqual(tokenizer.tokenize("it’s a cat’s toy"), tokenizer.tokenize("it's a cat's toy"))
    // The same letter, composed or as letter + combining accent.
    XCTAssertEqual(tokenizer.tokenize("cafe\u{301}"), tokenizer.tokenize("café"))
  }

  func testWithoutMergeRulesWordsFallBackToSingleBytes() {
    let tokenizer = CLIPTokenizer(
      merges: [], contextLength: 8, startToken: 510, endToken: 511, padToken: 0)
    // "!" is the first printable byte (id 0); as a whole word it takes the
    // end-of-word form, 256 ids later.
    XCTAssertEqual(tokenizer.encode("!"), [256])
    XCTAssertEqual(tokenizer.tokenize("!"), [510, 256, 511, 0, 0, 0, 0, 0])
  }
}
