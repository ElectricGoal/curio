import CoreGraphics
import Foundation
import ImageIO

/// A picture cut into the patches a d1 model's vision tower reads.
struct D1Picture: Sendable {
  /// One row per patch: `channels × frames × patch × patch` values in -1…1.
  let patches: [Float]
  /// Patches down and across.
  let rows: Int
  let columns: Int

  var patchCount: Int { rows * columns }
}

/// How pictures are sized and laid out for LFM3 vision towers.
///
/// Adapted from the image processor shipped with the LiquidAI checkpoints.
struct D1PictureLayout: Equatable, Sendable {
  var patch = 16
  /// Patches are read in `merge × merge` blocks; each block becomes one token.
  var merge = 2
  /// A still picture is given as this many identical frames.
  var frames = 2
  var channels = 3
  var minPixels = 65_536
  var maxPixels = 1_638_400
  /// The longest side a picture is reduced to before anything else. Smaller is
  /// faster: time grows with the number of tokens, which grows with the area.
  var longestSide = 384

  var block: Int { patch * merge }
  var valuesPerPatch: Int { channels * frames * patch * patch }

  /// The size a `width × height` picture is drawn at: whole blocks, within the pixel limits.
  func size(width: Int, height: Int) throws -> (width: Int, height: Int) {
    guard width > 0, height > 0, max(width, height) <= 200 * min(width, height) else {
      throw EngineError.failed("The picture is too narrow for the model to read.")
    }
    var w = Double(width)
    var h = Double(height)
    let longest = max(w, h)
    if longest > Double(longestSide) {
      let scale = Double(longestSide) / longest
      w = max(1, (w * scale).rounded())
      h = max(1, (h * scale).rounded())
    }
    let factor = Double(block)
    // Halves round to the even neighbour, as the reference processor's do.
    var across = max(factor, (w / factor).rounded(.toNearestOrEven) * factor)
    var down = max(factor, (h / factor).rounded(.toNearestOrEven) * factor)
    if across * down > Double(maxPixels) {
      let beta = (w * h / Double(maxPixels)).squareRoot()
      across = max(factor, (w / beta / factor).rounded(.down) * factor)
      down = max(factor, (h / beta / factor).rounded(.down) * factor)
    } else if across * down < Double(minPixels) {
      let beta = (Double(minPixels) / (w * h)).squareRoot()
      across = (w * beta / factor).rounded(.up) * factor
      down = (h * beta / factor).rounded(.up) * factor
    }
    return (Int(across), Int(down))
  }

  /// Reads a picture file: upright, in sRGB, transparent areas on white.
  func picture(at url: URL) throws -> D1Picture {
    let name = url.lastPathComponent
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw ImagePreprocessor.Failure.unreadable(name)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      // Decoded larger than needed so the final scale has detail to work from.
      kCGImageSourceThumbnailMaxPixelSize: longestSide * 2,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw ImagePreprocessor.Failure.undecodable(name)
    }
    do {
      return try picture(from: image)
    } catch {
      // Too narrow to cut into patches, or could not be drawn: true of this file
      // until it changes, so it is reported like any other picture that cannot be read.
      throw ImagePreprocessor.Failure.undecodable(name)
    }
  }

  func picture(from image: CGImage) throws -> D1Picture {
    let target = try size(width: image.width, height: image.height)
    let failure = EngineError.failed("An image could not be drawn at the size the model needs.")
    guard let colours = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: target.width, height: target.height, bitsPerComponent: 8,
        bytesPerRow: target.width * 4, space: colours,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw failure }
    let frame = CGRect(x: 0, y: 0, width: target.width, height: target.height)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(frame)
    context.interpolationQuality = .high
    context.draw(image, in: frame)
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw failure }
    let bytes = UnsafeBufferPointer(start: pixels, count: target.width * target.height * 4)
    return picture(rgba: bytes, width: target.width, height: target.height)
  }

  /// Lays out `width × height` RGBA pixels (whole blocks) as patches: block by
  /// block, the patches of a block together, each patch written channel by
  /// channel, frame by frame, row by row.
  func picture(rgba: UnsafeBufferPointer<UInt8>, width: Int, height: Int) -> D1Picture {
    let rows = height / patch
    let columns = width / patch
    var values = [Float](repeating: 0, count: rows * columns * valuesPerPatch)
    values.withUnsafeMutableBufferPointer { out in
      var cursor = 0
      for blockRow in 0..<(rows / merge) {
        for blockColumn in 0..<(columns / merge) {
          for inRow in 0..<merge {
            for inColumn in 0..<merge {
              let top = (blockRow * merge + inRow) * patch
              let left = (blockColumn * merge + inColumn) * patch
              for channel in 0..<channels {
                for _ in 0..<frames {
                  for y in 0..<patch {
                    let line = ((top + y) * width + left) * 4 + channel
                    for x in 0..<patch {
                      // 0…255 to -1…1: the mean and deviation are both one half.
                      out[cursor] = Float(rgba[line + x * 4]) / 127.5 - 1
                      cursor += 1
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    return D1Picture(patches: values, rows: rows, columns: columns)
  }
}
