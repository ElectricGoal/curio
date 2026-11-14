import XCTest

@testable import Luma

/// The image loader answers each waiting view exactly once, whether the
/// decode, a cancellation, or the continuation itself arrives first.
final class SingleReplyTests: XCTestCase {
  func testValueSentAfterAttachIsDelivered() async {
    let reply = SingleReply<Int>()
    let value = await withCheckedContinuation { continuation in
      reply.attach(continuation)
      reply.send(7)
    }
    XCTAssertEqual(value, 7)
  }

  func testValueSentBeforeAttachIsDelivered() async {
    let reply = SingleReply<Int>()
    reply.send(3)
    let value = await withCheckedContinuation { reply.attach($0) }
    XCTAssertEqual(value, 3)
  }

  func testOnlyTheFirstValueCounts() async {
    let reply = SingleReply<Int>()
    let value = await withCheckedContinuation { continuation in
      reply.attach(continuation)
      reply.send(1)
      reply.send(2)  // must not resume the continuation a second time
    }
    XCTAssertEqual(value, 1)
  }

  func testCancelledLoadsReturnInsteadOfWaitingForever() async {
    // Far more requests than the decoder runs at once, all cancelled at once:
    // every one of them must still come back.
    let tasks = (0..<200).map { index in
      Task { await ImageLoader.shared.load("/nonexistent/\(index).jpg", maxPixel: 64) }
    }
    tasks.forEach { $0.cancel() }
    for task in tasks {
      let loaded = await task.value
      XCTAssertNil(loaded)
    }
  }
}
