import AppKit
import ImageIO
import SwiftUI

/// Decodes downsized images off the main thread and remembers recent ones,
/// so scrolling back through the grid does not decode the same files again.
final class ImageLoader: @unchecked Sendable {
  static let shared = ImageLoader()

  struct Loaded {
    let image: NSImage
    /// Pixel size of the original file, when the file declares it.
    let originalSize: CGSize?
  }

  private let cache = NSCache<NSString, NSImage>()
  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "curio.image-decoding"
    queue.maxConcurrentOperationCount = 6
    queue.qualityOfService = .userInitiated
    return queue
  }()

  private init() {
    cache.totalCostLimit = 384 * 1024 * 1024
  }

  func cached(_ path: String, maxPixel: Int) -> NSImage? {
    cache.object(forKey: Self.key(path, maxPixel))
  }

  /// A downsized image for `path`, or nil if it cannot be decoded or the
  /// requesting view went away first.
  func image(at path: String, maxPixel: Int) async -> NSImage? {
    if let hit = cached(path, maxPixel: maxPixel) { return hit }
    return await load(path, maxPixel: maxPixel)?.image
  }

  func load(_ path: String, maxPixel: Int) async -> Loaded? {
    let operation = BlockOperation()
    let reply = SingleReply<Loaded?>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Loaded?, Never>) in
        reply.attach(continuation)
        operation.addExecutionBlock { [self, unowned operation] in
          guard !operation.isCancelled, let loaded = Self.decode(path, maxPixel: maxPixel) else {
            reply.send(nil)
            return
          }
          let pixels = loaded.image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
          cache.setObject(loaded.image, forKey: Self.key(path, maxPixel), cost: pixels * 4)
          reply.send(loaded)
        }
        queue.addOperation(operation)
      }
    } onCancel: {
      // A cancelled operation that has not started never runs its block, so
      // the waiting view must be answered here or it would wait forever.
      operation.cancel()
      reply.send(nil)
    }
  }

  private static func key(_ path: String, _ maxPixel: Int) -> NSString {
    "\(maxPixel)|\(path)" as NSString
  }

  private static func decode(_ path: String, maxPixel: Int) -> Loaded? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixel,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { return nil }
    return Loaded(
      image: NSImage(cgImage: image, size: .zero), originalSize: originalSize(of: source))
  }

  private static func originalSize(of source: CGImageSource) -> CGSize? {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Double,
      let height = properties[kCGImagePropertyPixelHeight] as? Double
    else { return nil }
    // EXIF orientations 5–8 are rotated a quarter turn on display.
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
  }
}

/// Delivers one value to one continuation, whichever of several callers gets
/// there first, and whether the value or the continuation arrives first.
final class SingleReply<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Never>?
  private var pending: Value?
  private var finished = false

  func attach(_ continuation: CheckedContinuation<Value, Never>) {
    lock.lock()
    if finished, let value = pending {
      pending = nil
      lock.unlock()
      continuation.resume(returning: value)
    } else {
      self.continuation = continuation
      lock.unlock()
    }
  }

  func send(_ value: Value) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    if let continuation {
      self.continuation = nil
      lock.unlock()
      continuation.resume(returning: value)
    } else {
      pending = value
      lock.unlock()
    }
  }
}

/// An image cropped to fill whatever frame it is given, loaded lazily.
struct Thumbnail: View {
  static let maxPixel = 480

  let path: String
  @State private var image: NSImage?
  @State private var failed = false

  var body: some View {
    // The image sits in an overlay so a wide photo cannot stretch its cell.
    Rectangle().fill(Theme.muted)
      .overlay {
        if let image {
          Image(nsImage: image).resizable().scaledToFill()
        } else if failed {
          // Says what happened in words; an icon alone would not.
          Text("Can’t preview").font(.swissCaption).foregroundStyle(Theme.mutedForeground)
        }
      }
      .clipped()
    .task(id: path) {
      if let hit = ImageLoader.shared.cached(path, maxPixel: Self.maxPixel) {
        image = hit
        return
      }
      image = nil
      failed = false
      let loaded = await ImageLoader.shared.image(at: path, maxPixel: Self.maxPixel)
      guard !Task.isCancelled else { return }
      image = loaded
      failed = loaded == nil
    }
  }
}
