import Foundation

public enum Format {
  public static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }

  public static func count(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
  }

  /// "1 image" / "2,300 images".
  public static func images(_ value: Int) -> String {
    count(value) + (value == 1 ? " image" : " images")
  }

  /// A coarse, human "about 3 min left" for a number of seconds.
  public static func remaining(_ seconds: Double) -> String {
    switch seconds {
    case ..<5: return "a few seconds left"
    case ..<50: return "about \(Int((seconds / 5).rounded(.up)) * 5) sec left"
    case ..<3300: return "about \(max(1, Int((seconds / 60).rounded()))) min left"
    default:
      let hours = seconds / 3600
      return "about \(hours < 1.25 ? "1 hr" : String(format: "%.1f hr", hours)) left"
    }
  }

  /// Search scores are cosine similarities; shown as a whole percent.
  public static func score(_ value: Double) -> String {
    "\(Int((max(0, min(1, value)) * 100).rounded()))%"
  }
}
