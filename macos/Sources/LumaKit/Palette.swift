import Foundation

/// An sRGB colour, with the WCAG maths needed to check it is legible.
public struct RGB: Equatable, Sendable {
  public let hex: UInt32

  public init(_ hex: UInt32) {
    self.hex = hex
  }

  public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
  public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
  public var blue: Double { Double(hex & 0xFF) / 255 }

  /// WCAG 2 relative luminance.
  public var luminance: Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// WCAG 2 contrast ratio between two colours, from 1 (none) to 21.
  public static func contrast(_ first: RGB, _ second: RGB) -> Double {
    let lighter = max(first.luminance, second.luminance)
    let darker = min(first.luminance, second.luminance)
    return (lighter + 0.05) / (darker + 0.05)
  }
}

/// The app's colours for one appearance.
///
/// Minimalism & Swiss Style: monochrome surfaces and type, hairline borders in
/// place of shadows, and a single accent. Every value has a role; views never
/// use raw colours.
public struct Palette: Equatable, Sendable {
  /// The window behind everything.
  public let background: RGB
  /// Panels and the sidebar.
  public let surface: RGB
  /// Placeholders and hovered rows.
  public let muted: RGB
  public let foreground: RGB
  /// Secondary text, and the outline of controls at rest.
  public let mutedForeground: RGB
  /// Dividers. Decorative only: too faint to mark a control's edge.
  public let border: RGB
  /// Primary buttons, selection and focus: the "black" of the system.
  public let ink: RGB
  public let onInk: RGB
  /// The one accent: progress, the copy to keep, similarity scores.
  public let accent: RGB
  public let onAccent: RGB
  public let destructive: RGB
  public let onDestructive: RGB

  /// "Monochrome + blue accent".
  public static let light = Palette(
    background: RGB(0xFAFAFA), surface: RGB(0xFFFFFF), muted: RGB(0xE8ECF0),
    foreground: RGB(0x09090B), mutedForeground: RGB(0x475569), border: RGB(0xE4E4E7),
    ink: RGB(0x18181B), onInk: RGB(0xFFFFFF), accent: RGB(0x2563EB), onAccent: RGB(0xFFFFFF),
    destructive: RGB(0xDC2626), onDestructive: RGB(0xFFFFFF))

  /// "Pure black + white contrast": in the dark, the accent is white itself.
  public static let dark = Palette(
    background: RGB(0x000000), surface: RGB(0x0C0C0C), muted: RGB(0x181818),
    foreground: RGB(0xFAFAFA), mutedForeground: RGB(0x94A3B8), border: RGB(0x3F3F46),
    ink: RGB(0xF8FAFC), onInk: RGB(0x0F172A), accent: RGB(0xF8FAFC), onAccent: RGB(0x0F172A),
    destructive: RGB(0xEF4444), onDestructive: RGB(0x000000))
}
