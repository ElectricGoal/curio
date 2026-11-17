import XCTest

@testable import CurioKit

/// The Swift decision model against mlx-vlm's, step by step: the same tokens,
/// the same prompt, the same picture tensor, the same answers.
final class D1ReferenceTests: XCTestCase {
  func testTokenizerMatchesTheReference() throws {
    let reference = try D1Fixtures.reference()
    let tokenizer = try D1Fixtures.tokenizer()
    for sample in reference.tokenizer {
      XCTAssertEqual(tokenizer.encode(sample.text), sample.ids, "tokens of “\(sample.text)”")
    }
  }

  func testQuestionsAreWrittenAsTheReferenceWritesThem() throws {
    let reference = try D1Fixtures.reference()
    let prompt = try D1Prompt(tokenizer: try D1Fixtures.tokenizer())
    for sample in reference.escaped {
      XCTAssertEqual(prompt.suffix(sample.text), sample.suffix, "question “\(sample.text)”")
    }
    XCTAssertEqual(prompt.yesTokens, reference.yesTokens)
    XCTAssertEqual(prompt.noTokens, reference.noTokens)
  }

  func testRowMatchesTheReference() throws {
    let reference = try D1Fixtures.reference()
    let prompt = try D1Prompt(tokenizer: try D1Fixtures.tokenizer())
    let row = try prompt.row(imageTokens: reference.featuresShape[0], questions: reference.questions)
    XCTAssertEqual(row.ids, reference.ids)
    XCTAssertEqual(row.stateLength, reference.stateLength)
    XCTAssertEqual(row.groups, reference.groups)
    XCTAssertEqual(row.slots, reference.slots)
    XCTAssertEqual(D1Masks.fullValues(row).filter { $0 }.count, reference.fullMaskTrue)
  }

  func testPictureIsCutIntoTheSamePatches() async throws {
    let reference = try D1Fixtures.reference()
    let model = try await D1Fixtures.model()
    let picture = try model.layout.picture(at: D1Fixtures.picture)
    XCTAssertEqual([picture.rows, picture.columns], reference.grid)
    let width = reference.patchValues
    XCTAssertEqual(picture.patches.count, picture.patchCount * width)
    XCTAssertEqual(picture.patches.reduce(0.0) { $0 + Double($1) }, reference.patchSum, accuracy: 1)
    for sample in reference.patches {
      let own = Array(picture.patches[(sample.index * width)..<((sample.index + 1) * width)])
      let worst = zip(own, sample.values).map { abs($0 - $1) }.max() ?? 1
      XCTAssertLessThan(worst, 1e-5, "patch \(sample.index)")
    }
  }

  func testVisionTowerMatchesTheReference() async throws {
    let reference = try D1Fixtures.reference()
    let model = try await D1Fixtures.model()
    let rows = try await model.featureRows(of: D1Fixtures.picture, count: 32)
    XCTAssertEqual(rows.count, reference.featuresShape[0])
    for sample in reference.features {
      let worst = zip(rows[sample.index], sample.values).map { abs($0 - $1) }.max() ?? 1
      // Half-precision arithmetic in a different order: close, not identical.
      XCTAssertLessThan(worst, 0.05, "features of token \(sample.index)")
    }
  }

  func testAnswersMatchTheReference() async throws {
    let reference = try D1Fixtures.reference()
    let model = try await D1Fixtures.model()
    let answers = try await model.decide(image: D1Fixtures.picture, questions: reference.questions)
    XCTAssertEqual(answers.count, reference.answers.count)
    for (own, expected) in zip(answers, reference.answers) {
      XCTAssertEqual(own, expected, accuracy: 0.01)
    }
    let alone = try await model.decide(image: D1Fixtures.picture, questions: [reference.questions[0]])
    XCTAssertEqual(alone[0], reference.answerAlone, accuracy: 0.01)
  }

  /// The four-bit checkpoint runs on the same code: only how its weights are packed differs.
  func testTheFourBitCheckpointMatchesItsReference() async throws {
    let alias = D1Fixtures.compactAlias
    let reference = try D1Fixtures.reference(of: alias)
    let model = try await D1Fixtures.compactModel()
    let rows = try await model.featureRows(of: D1Fixtures.picture(of: alias), count: 32)
    XCTAssertEqual(rows.count, reference.featuresShape[0])
    for sample in reference.features {
      let worst = zip(rows[sample.index], sample.values).map { abs($0 - $1) }.max() ?? 1
      XCTAssertLessThan(worst, 0.05, "features of token \(sample.index)")
    }
    let answers = try await model.decide(
      image: D1Fixtures.picture(of: alias), questions: reference.questions)
    XCTAssertEqual(answers.count, reference.answers.count)
    for (own, expected) in zip(answers, reference.answers) {
      XCTAssertEqual(own, expected, accuracy: 0.01)
    }
  }

  func testAnswerDoesNotDependOnTheOtherQuestions() async throws {
    let reference = try D1Fixtures.reference()
    let model = try await D1Fixtures.model()
    let forwards = try await model.decide(image: D1Fixtures.picture, questions: reference.questions)
    let backwards = try await model.decide(
      image: D1Fixtures.picture, questions: reference.questions.reversed())
    // Position in the row shifts each question a little, as in the reference
    // (0.42 alone against 0.43 with two others there); a question that could
    // read its neighbours would move far more.
    for (own, other) in zip(forwards, backwards.reversed()) {
      XCTAssertEqual(own, other, accuracy: 0.05)
    }
  }
}
