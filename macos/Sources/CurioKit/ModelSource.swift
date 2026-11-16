import Foundation

/// Where a model's files are downloaded from, in a form to show a person and to open.
public struct ModelSource: Decodable, Sendable, Equatable {
  /// Short enough to read at a glance: "huggingface.co/LiquidAI/d1-2B-MLX-8bit".
  public let label: String
  /// A page where the files can be seen before downloading them.
  public let page: URL

  private static let huggingFace = "huggingface.co"

  public init(label: String, page: URL) {
    self.label = label
    self.page = page
  }

  /// - Parameter downloadBase: the address the app fetches the model's files under.
  public init?(downloadBase: URL) {
    if downloadBase.isFileURL {
      self.init(label: downloadBase.path, page: downloadBase)
      return
    }
    guard let host = downloadBase.host, !host.isEmpty else { return nil }
    let parts = downloadBase.path.split(separator: "/").map(String.init)
    // Hugging Face serves files at /<owner>/<repository>/resolve/<revision>/…
    // and shows the same files to people at /<owner>/<repository>/tree/<revision>/…
    if host == Self.huggingFace, parts.count >= 4, parts[2] == "resolve",
      let page = URL(
        string: "https://\(host)/" + (parts[0..<2] + ["tree"] + parts[3...]).joined(separator: "/"))
    {
      self.init(label: "\(host)/\(parts[0])/\(parts[1])", page: page)
    } else {
      self.init(label: host + downloadBase.path, page: downloadBase)
    }
  }
}
