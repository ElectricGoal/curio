import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// An image file made ready for the image encoder.
public struct PreparedImage: Sendable {
  /// Red, green then blue planes, each `side × side` values in 0…1.
  public let tensor: [Float]
  /// SHA-1 of the file's bytes, used to spot identical files and real changes.
  public let sha1: String
  /// Size of the original picture as displayed (after any rotation).
  public let width: Int
  public let height: Int
}

/// Turns image files into model input.
///
/// The whole picture is scaled to the square the model expects (not cropped),
/// drawn upright, in sRGB, with transparent areas on white — so what the model
/// sees is what a person sees when they open the file.
public enum ImagePreprocessor {
  /// Why a file could not be prepared. The difference matters to indexing: a
  /// file that is not a picture stays that way, but one that could not be read
  /// may be readable next time (a drive reconnected, a download finished).
  public enum Failure: LocalizedError, Equatable {
    /// The file is no longer where it was.
    case missing(String)
    /// The file is there but this app is not allowed to open it.
    case noPermission(String)
    /// Reading the file failed part-way or for another reason.
    case unreadable(String)
    /// The file was read but is not an image this Mac can decode.
    case undecodable(String)

    public var errorDescription: String? {
      switch self {
      case .missing(let name): return "\(name) could not be found."
      case .noPermission(let name): return "\(name) could not be opened: permission denied."
      case .unreadable(let name): return "Could not read \(name)."
      case .undecodable(let name): return "Could not decode \(name)."
      }
    }

    /// True when trying again later cannot help unless the file itself changes.
    public var isPermanent: Bool {
      switch self {
      case .noPermission, .undecodable: return true
      case .missing, .unreadable: return false
      }
    }
  }

  /// How much larger than the target a wide or tall picture may be decoded
  /// before the final scale, so narrow details survive the squeeze.
  private static let maxOversample = 4

  public static func prepare(_ url: URL, side: Int) throws -> PreparedImage {
    let name = url.lastPathComponent
    let data: Data
    do {
      data = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    {
      throw Failure.missing(name)
    } catch let error as CocoaError where error.code == .fileReadNoPermission {
      throw Failure.noPermission(name)
    } catch {
      throw Failure.unreadable(name)
    }
    let digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = upright(source, side: side),
      let tensor = try? tensor(from: image, side: side)
    else { throw Failure.undecodable(name) }
    let size = displaySize(of: source) ?? (image.width, image.height)
    return PreparedImage(tensor: tensor, sha1: digest, width: size.0, height: size.1)
  }

  /// Decodes at a reduced size (fast for large photos) with rotation applied.
  private static func upright(_ source: CGImageSource, side: Int) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: side * maxOversample,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func displaySize(of source: CGImageSource) -> (Int, Int)? {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    // EXIF orientations 5–8 are shown rotated a quarter turn.
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return orientation >= 5 ? (height, width) : (width, height)
  }

  /// Scales `image` to `side × side` and returns its planes in 0…1.
  public static func tensor(from image: CGImage, side: Int) throws -> [Float] {
    // Failing here must not hand back a blank picture: it would be indexed as one.
    let failure = EngineError.failed("An image could not be drawn at the size the model needs.")
    guard side > 0, let colours = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: colours, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw failure }
    var tensor = [Float](repeating: 1, count: 3 * side * side)
    let frame = CGRect(x: 0, y: 0, width: side, height: side)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(frame)
    context.interpolationQuality = .high
    context.draw(image, in: frame)
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw failure }
    let plane = side * side
    tensor.withUnsafeMutableBufferPointer { values in
      for index in 0..<plane {
        values[index] = Float(pixels[index * 4]) / 255
        values[plane + index] = Float(pixels[index * 4 + 1]) / 255
        values[2 * plane + index] = Float(pixels[index * 4 + 2]) / 255
      }
    }
    return tensor
  }
}
