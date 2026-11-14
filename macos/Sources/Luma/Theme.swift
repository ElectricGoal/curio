import AppKit
import LumaKit
import SwiftUI

/// Design tokens: Minimalism & Swiss Style.
///
/// Monochrome surfaces and type, one accent, square corners, hairlines instead
/// of shadows, and a single spacing scale. Views take every colour, distance
/// and type size from here; the colour values themselves live in `Palette`,
/// where their contrast is tested.
enum Theme {
  // MARK: Colour (follows the system's light or dark appearance)

  static let background = adaptive(\.background)
  static let surface = adaptive(\.surface)
  static let muted = adaptive(\.muted)
  static let foreground = adaptive(\.foreground)
  static let mutedForeground = adaptive(\.mutedForeground)
  static let border = adaptive(\.border)
  static let ink = adaptive(\.ink)
  static let onInk = adaptive(\.onInk)
  static let accent = adaptive(\.accent)
  static let destructive = adaptive(\.destructive)
  static let onDestructive = adaptive(\.onDestructive)

  private static func adaptive(_ role: KeyPath<Palette, RGB>) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let rgb = (dark ? Palette.dark : Palette.light)[keyPath: role]
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
      })
  }

  // MARK: Space (one scale; nothing in between)

  enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
  }

  /// The margin every page shares, so content hangs from one left edge.
  static let gutter = Space.xl
  static let sidebarWidth: CGFloat = 216

  // MARK: Line

  /// Dividers and panel edges.
  static let hairline: CGFloat = 1
  /// Selection, focus and emphasis.
  static let rule: CGFloat = 2

  // MARK: Motion

  /// Hover and press feedback. Skipped entirely under Reduce Motion.
  static let quick: Double = 0.2

  // MARK: Icon

  enum Icon {
    static let small: CGFloat = 11
    static let medium: CGFloat = 14
  }
}

// MARK: - Type

extension Font {
  /// Page titles.
  static let swissDisplay = Font.largeTitle.weight(.bold)
  /// Section and empty-state headings.
  static let swissHeading = Font.title2.weight(.semibold)
  /// Panel titles and row names.
  static let swissTitle = Font.headline
  static let swissBody = Font.body
  static let swissCaption = Font.caption
  /// Small capitals for labels and tags.
  static let swissLabel = Font.caption2.weight(.semibold)
}

/// Small capitalised section label.
struct Eyebrow: View {
  let text: String

  var body: some View {
    Text(text.uppercased()).font(.swissLabel).tracking(1.2)
      .foregroundStyle(Theme.mutedForeground)
  }
}

/// A square label: outlined, or filled when it marks the chosen thing.
struct Tag: View {
  let text: String
  var filled = false

  var body: some View {
    Text(text.uppercased()).font(.swissLabel).tracking(0.8)
      .padding(.horizontal, 6).padding(.vertical, 3)
      .foregroundStyle(filled ? Theme.onInk : Theme.foreground)
      .background(filled ? Theme.ink : Theme.surface)
      .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.hairline))
  }
}

/// A horizontal divider.
struct Hairline: View {
  var body: some View {
    Rectangle().fill(Theme.border).frame(height: Theme.hairline).accessibilityHidden(true)
  }
}

// MARK: - Containers

extension View {
  /// A bordered panel. `emphasis` adds a rule down the leading edge.
  func panel(emphasis: Color? = nil, padding: CGFloat = Theme.Space.m) -> some View {
    self.padding(padding)
      .background(Theme.surface)
      .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: Theme.hairline))
      .overlay(alignment: .leading) {
        if let emphasis { Rectangle().fill(emphasis).frame(width: Theme.rule) }
      }
  }
}

// MARK: - Controls

/// Square buttons in three weights, with hover, press and disabled states.
struct SwissButtonStyle: ButtonStyle {
  enum Kind {
    /// The one main action in view: filled with ink.
    case primary
    /// Everything else: outlined.
    case secondary
    /// Low-emphasis actions inside rows and bars: text only.
    case quiet
  }

  var kind: Kind = .secondary
  var destructive = false
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    Surface(style: self, configuration: configuration)
  }

  private struct Surface: View {
    let style: SwissButtonStyle
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(.callout.weight(.medium)).lineLimit(1)
        .padding(.horizontal, style.kind == .quiet ? Theme.Space.s : Theme.Space.m)
        .padding(.vertical, style.compact ? Theme.Space.xs : 6)
        .foregroundStyle(foreground)
        .background(background)
        .overlay(Rectangle().strokeBorder(outline, lineWidth: Theme.hairline))
        .contentShape(Rectangle())
        .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.quick), value: hovering)
    }

    private var tone: Color { style.destructive ? Theme.destructive : Theme.ink }

    private var foreground: Color {
      switch style.kind {
      case .primary: return style.destructive ? Theme.onDestructive : Theme.onInk
      case .secondary, .quiet: return style.destructive ? Theme.destructive : Theme.foreground
      }
    }

    private var background: Color {
      let active = hovering && isEnabled
      switch style.kind {
      case .primary: return tone.opacity(active ? 0.82 : 1)
      case .secondary, .quiet: return active ? Theme.muted : .clear
      }
    }

    private var outline: Color {
      switch style.kind {
      case .primary, .secondary: return tone
      case .quiet: return .clear
      }
    }
  }
}

extension ButtonStyle where Self == SwissButtonStyle {
  static var swissPrimary: SwissButtonStyle { SwissButtonStyle(kind: .primary) }
  static var swiss: SwissButtonStyle { SwissButtonStyle(kind: .secondary) }
  static var swissQuiet: SwissButtonStyle { SwissButtonStyle(kind: .quiet) }
}

/// A button showing only a symbol, with the name assistive tech and tooltips need.
struct IconButton: View {
  let symbol: String
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: Theme.Icon.medium, weight: .medium))
        .frame(width: 20, height: 20)
    }
    .buttonStyle(SwissButtonStyle(kind: .quiet, compact: true))
    .accessibilityLabel(label).help(label)
  }
}

/// A thin, square progress bar from 0 to 1.
struct ProgressRule: View {
  let value: Double
  let label: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { area in
      Rectangle().fill(Theme.border)
        .overlay(alignment: .leading) {
          Rectangle().fill(Theme.accent)
            .frame(width: area.size.width * min(1, max(0, value)))
        }
    }
    .frame(height: Theme.Space.xs)
    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: value)
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityValue("\(Int(min(1, max(0, value)) * 100)) percent")
  }
}
