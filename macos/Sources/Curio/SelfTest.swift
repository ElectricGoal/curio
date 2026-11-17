import CoreGraphics
import Foundation
import ImageIO
import CurioKit
import UniformTypeIdentifiers

/// `Curio --self-test`: proves this copy of the app can index and search
/// with the models it has, without opening a window. Used to check a packaged
/// build before it is released; it touches only a temporary folder.
enum SelfTest {
  static let flag = "--self-test"
  private static let colours: [(name: String, red: CGFloat, green: CGFloat, blue: CGFloat)] = [
    ("red", 0.86, 0.12, 0.12), ("green", 0.12, 0.67, 0.24), ("blue", 0.12, 0.24, 0.86),
  ]

  /// Runs the test and returns the process exit code.
  static func run(installation: Installation, bundledModels: URL?, shaders: URL?) async -> Int32 {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("curio-self-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: scratch) }
    do {
      let photos = scratch.appendingPathComponent("photos")
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      for colour in colours {
        try write(colour, to: photos.appendingPathComponent(colour.name + ".png"))
      }
      // First what needs no model: every copy of the app must be able to use the GPU through MLX.
      guard let shaders else { throw EngineError.failed("this app is missing its GPU shaders (mlx.metallib)") }
      try D1DecisionModel.checkGPU(shaders: shaders)
      print("self-test: MLX computes on the GPU with the app's shaders")
      // Models come from this copy of the app; everything written goes to scratch.
      let library = ModelLibrary(
        installDirectory: installation.dataRoot.appendingPathComponent("models/coreml"),
        bundledDirectory: bundledModels)
      let installed = library.models().filter(\.installed)
      guard !installed.isEmpty else {
        print("self-test FAILED: no model is installed in or alongside this app")
        return 1
      }
      for model in installed {
        guard let directory = library.directory(for: model.alias) else { continue }
        let cache = scratch.appendingPathComponent("compiled/\(model.alias)")
        let engine = NativeEngine(dataRoot: scratch.appendingPathComponent("data")) { _ in
          try await CoreMLEmbeddingModel.load(directory: directory, cache: cache)
        }
        let started = Date()
        let indexed = try await engine.index(
          folder: photos, model: model.alias, rebuild: true, expected: colours.count
        ) { _ in }
        guard indexed.count == colours.count else {
          print("self-test FAILED: \(model.alias) indexed \(indexed.count) of \(colours.count) images")
          return 1
        }
        for colour in colours {
          let found = try await engine.search(
            folder: photos, text: "a solid \(colour.name) square", limit: 1
          ) { _ in }
          guard found.images.first?.name == colour.name + ".png" else {
            print(
              "self-test FAILED: \(model.alias) answered “\(colour.name)” with \(found.images.first?.name ?? "nothing")"
            )
            return 1
          }
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        print("self-test: \(model.name) indexed \(indexed.count) images and found each by description (\(seconds)s)")
      }
      try await checkDecisions(installation: installation, shaders: shaders, photos: photos)
      print("self-test passed")
      return 0
    } catch {
      print("self-test FAILED: \(error.localizedDescription)")
      return 1
    }
  }

  /// Careful filter steps: each decision model is asked, where it has been downloaded.
  private static func checkDecisions(installation: Installation, shaders: URL, photos: URL) async throws {
    let library = DecisionLibrary(installDirectory: installation.dataRoot.appendingPathComponent("models/mlx"))
    let installed = DecisionCatalog.entries.compactMap { entry in
      library.directory(for: entry.alias).map { (entry.alias, $0) }
    }
    if installed.isEmpty {
      print("self-test: no decision model is installed; careful filter steps were not exercised")
    }
    for (alias, directory) in installed {
      try await checkDecisions(alias: alias, directory: directory, shaders: shaders, photos: photos)
      // The next one is read into memory the last has given back.
      D1DecisionModel.releaseBuffers()
    }
  }

  private static func checkDecisions(alias: String, directory: URL, shaders: URL, photos: URL)
    async throws
  {
    let started = Date()
    let model = try await D1DecisionModel.load(alias: alias, directory: directory, shaders: shaders)
    let question = "Is this image a solid red square?"
    for colour in colours {
      let answer = try await model.decide(
        image: photos.appendingPathComponent(colour.name + ".png"), questions: [question])
      guard let probability = answer.first, (probability >= 0.5) == (colour.name == "red") else {
        throw EngineError.failed(
          "\(alias) answered “\(question)” with \(answer.first.map { String(format: "%.2f", $0) } ?? "nothing") for the \(colour.name) square")
      }
    }
    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
    print("self-test: \(DecisionCatalog.entry(alias)?.name ?? alias) told the red square from the others (\(seconds)s)")
  }

  private static func write(
    _ colour: (name: String, red: CGFloat, green: CGFloat, blue: CGFloat), to url: URL
  ) throws {
    let side = 256
    guard
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw EngineError.failed("could not create a test image") }
    context.setFillColor(
      CGColor(srgbRed: colour.red, green: colour.green, blue: colour.blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw EngineError.failed("could not create a test image") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw EngineError.failed("could not write a test image")
    }
  }
}
