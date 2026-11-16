import CurioKit
import Foundation

/// What the footer says: the folder, its index and the model, in a few words each.
extension Studio {
  /// How many images the open folder holds; nil with no folder open.
  var footerImages: String? {
    folder == nil ? nil : Format.images(library.count)
  }

  /// The state of the folder's search index; nil with no folder open.
  var footerIndex: String? {
    guard folder != nil else { return nil }
    if engineProblem != nil { return "Search unavailable" }
    guard let status = indexStatus else { return "Checking index…" }
    if status.needsRebuild { return "Index out of date" }
    guard status.indexed else { return "Not indexed" }
    let searchable = "\(Format.count(status.count)) searchable"
    return status.pending > 0 ? "\(searchable) · \(Format.count(status.pending)) new" : searchable
  }

  /// The model in play: the one this folder was indexed with, else the one new indexes will use.
  var footerModel: String {
    if let status = indexStatus, status.indexed, !status.needsRebuild, let name = status.modelName {
      return name
    }
    return selectedModelName
  }

  /// The latest message, unless it only repeats what the footer already shows.
  var footerMessage: String? {
    let shown = [footerImages, footerIndex].compactMap { $0 }
    return status.isEmpty || shown.contains(status) ? nil : status
  }
}
