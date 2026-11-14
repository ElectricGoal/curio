import XCTest

@testable import LumaKit

/// The theme must stay legible: these are the pairings the views actually use.
final class PaletteTests: XCTestCase {
  private let palettes = [("light", Palette.light), ("dark", Palette.dark)]

  func testContrastMathsMatchesTheWCAGReferenceValues() {
    XCTAssertEqual(RGB.contrast(RGB(0x000000), RGB(0xFFFFFF)), 21, accuracy: 0.01)
    XCTAssertEqual(RGB.contrast(RGB(0x777777), RGB(0xFFFFFF)), 4.48, accuracy: 0.01)
    XCTAssertEqual(RGB.contrast(RGB(0x2563EB), RGB(0x2563EB)), 1, accuracy: 0.0001)
  }

  func testBodyTextMeetsAA() {
    for (name, palette) in palettes {
      let pairs: [(String, RGB, RGB)] = [
        ("text on window", palette.foreground, palette.background),
        ("text on panel", palette.foreground, palette.surface),
        ("text on placeholder", palette.foreground, palette.muted),
        ("secondary text on window", palette.mutedForeground, palette.background),
        ("secondary text on panel", palette.mutedForeground, palette.surface),
        ("secondary text on hovered row", palette.mutedForeground, palette.muted),
        ("primary button label", palette.onInk, palette.ink),
        ("accent label", palette.onAccent, palette.accent),
        ("accent text on window", palette.accent, palette.background),
        ("accent text on panel", palette.accent, palette.surface),
        ("destructive text on window", palette.destructive, palette.background),
        ("destructive text on panel", palette.destructive, palette.surface),
        ("destructive button label", palette.onDestructive, palette.destructive),
      ]
      for (role, text, behind) in pairs {
        XCTAssertGreaterThanOrEqual(
          RGB.contrast(text, behind), 4.5, "\(name): \(role) is below 4.5:1")
      }
    }
  }

  func testControlsAndIndicatorsMeetThreeToOne() {
    for (name, palette) in palettes {
      let pairs: [(String, RGB, RGB)] = [
        ("control outline", palette.mutedForeground, palette.background),
        ("control outline on panel", palette.mutedForeground, palette.surface),
        ("selection rule", palette.ink, palette.surface),
        ("progress fill on its track", palette.accent, palette.border),
        ("kept-copy outline", palette.ink, palette.background),
      ]
      for (role, mark, behind) in pairs {
        XCTAssertGreaterThanOrEqual(
          RGB.contrast(mark, behind), 3, "\(name): \(role) is below 3:1")
      }
    }
  }

  func testThereIsOneAccentAndTheRestIsNeutral() {
    for (name, palette) in palettes {
      let neutrals = [
        palette.background, palette.surface, palette.muted, palette.foreground, palette.border,
        palette.ink,
      ]
      for color in neutrals {
        let spread = max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
        XCTAssertLessThan(spread, 0.04, "\(name): #\(String(color.hex, radix: 16)) is not neutral")
      }
    }
  }
}
