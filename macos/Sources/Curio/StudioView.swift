import AppKit
import CurioKit
import SwiftUI

/// The window: sidebar, page header and the current page, over a footer.
struct StudioView: View {
  @EnvironmentObject private var studio: Studio
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        SidebarView()
        content
      }
      FooterView()
    }
    .foregroundStyle(Theme.foreground)
    // The window has no title bar of its own: the app reaches to its top edge.
    .ignoresSafeArea(.container, edges: .top)
    .overlay {
      if let preview = studio.preview {
        PreviewView(state: preview)
          .transition(.opacity.combined(with: .scale(scale: 0.97)))
      }
    }
    // Opening and closing a photo glides instead of cutting; Reduce Motion keeps it instant.
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: studio.preview == nil)
    .tint(Theme.ink)
    .background(WindowChrome())
    .sheet(
      // Only the sheet's own buttons answer it; a presentation SwiftUI drops
      // (say, while the app is in the background) must not count as "Not Now".
      isPresented: Binding(get: { studio.needsModelSetup }, set: { _ in })
    ) {
      ModelSetupView().environmentObject(studio)
    }
    .dropDestination(for: URL.self) { urls, _ in studio.handleDrop(urls) }
    .alert(
      studio.alert?.title ?? "",
      isPresented: Binding(get: { studio.alert != nil }, set: { if !$0 { studio.alert = nil } }),
      presenting: studio.alert
    ) { shown in
      // Dismiss only the alert that was showing, not one raised since.
      Button("OK") { if studio.alert?.id == shown.id { studio.alert = nil } }
    } message: { alert in
      Text(alert.message)
    }
  }

  /// The page header and the page itself.
  private var content: some View {
      VStack(alignment: .leading, spacing: 0) {
        header
        page.padding(.top, Theme.Space.m)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          // On its own view: two alerts on one view can swallow each other.
          .alert("Index this folder first", isPresented: $studio.needsIndexPrompt) {
            Button("Index Now") { studio.indexFolder() }
            Button("Not Now", role: .cancel) {}
          } message: {
            Text(
              "Search and duplicate detection need a search index. Curio reads each image once and stores what it learns next to your photos. You can keep browsing while it works."
            )
          }
      }.background(Theme.background)
  }

  /// One row on the window's 52-pt top bar, as in Orca: the album's name and
  /// path on the left, its tabs in the centre, on the line of the window buttons.
  private var header: some View {
    HStack(alignment: .center, spacing: Theme.Space.l) {
      if studio.page == .settings {
        Text("Settings").font(.headline)
        Spacer(minLength: Theme.Space.m)
        if studio.folder != nil {
          Button("Done") { studio.page = .library }
            .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
            .keyboardShortcut(.cancelAction)
            .help("Back to the album (Esc)")
        }
      } else if let folder = studio.folder {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
          Text(folder.lastPathComponent).font(.headline).lineLimit(1).layoutPriority(1)
          Text((folder.path as NSString).abbreviatingWithTildeInPath)
            .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
            .lineLimit(1).truncationMode(.middle)
        }
        // Narrow enough never to reach the centred tabs, even in the smallest window.
        .frame(maxWidth: 220, alignment: .leading)
        .help(folder.path)
        Spacer(minLength: 0)
      } else {
        Spacer()
      }
    }
    .padding(.horizontal, Theme.gutter)
    .frame(height: Theme.titleRow)
    .overlay {
      // Centred in the content area, whatever the album's name.
      if studio.folder != nil, studio.page != .settings { PageTabs() }
    }
    // This row is where the title bar would be: it must act like one.
    .background(TitleBarArea())
    .overlay(alignment: .bottom) { Hairline() }
  }

  @ViewBuilder private var page: some View {
    switch studio.page {
    case .library: LibraryView()
    case .duplicates: DuplicatesView()
    case .cleanup: CleanUpView()
    case .filter: FilterView()
    case .settings: SettingsView()
    }
  }
}

/// The album's tabs, on a pill track. Duplicates and Clean Up show how many
/// extras they found; the chosen tab is raised, bold and marked as selected.
private struct PageTabs: View {
  @EnvironmentObject private var studio: Studio

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Page.tabs) { page in tab(page) }
    }
    .padding(2)
    .background(Theme.muted, in: RoundedRectangle(cornerRadius: Theme.radius))
    .fixedSize()
    .accessibilityElement(children: .contain).accessibilityLabel("Album tabs")
  }

  private func tab(_ page: Page) -> some View {
    let chosen = studio.page == page
    let badge = badge(page)
    return Button {
      studio.page = page
    } label: {
      HStack(spacing: Theme.Space.xs) {
        Text(page.title).font(.callout.weight(chosen ? .semibold : .regular))
        if let badge {
          Text(badge).font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Theme.border, in: Capsule())
        }
      }
      .padding(.horizontal, Theme.Space.m).padding(.vertical, 5)
      .foregroundStyle(chosen ? Theme.foreground : Theme.mutedForeground)
      .background(chosen ? Theme.background : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.controlRadius)
          .strokeBorder(chosen ? Theme.border : .clear, lineWidth: Theme.hairline))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(badge.map { "\(page.title), \($0)" } ?? page.title)
    .accessibilityAddTraits(chosen ? .isSelected : [])
  }

  private func badge(_ page: Page) -> String? {
    switch page {
    case .duplicates:
      guard let extras = studio.duplicates?.extras.count, extras > 0 else { return nil }
      return Format.count(extras)
    case .cleanup:
      let count = studio.junkCount
      return count > 0 ? Format.count(count) : nil
    case .library, .filter, .settings:
      return nil
    }
  }
}

/// Gives the window Orca's top bar: about 38 pt tall, with macOS's own window
/// buttons at their standard size, centred in it. An empty compact unified
/// toolbar is how macOS does that; the sidebar's title and the album row are
/// laid out on the same line (`Theme.titleRow`).
private struct WindowChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { ChromeView() }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class ChromeView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, window.toolbar == nil else { return }
      window.toolbar = NSToolbar(identifier: "Curio")
      window.toolbarStyle = .unifiedCompact
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
    }
  }
}

/// Makes the empty parts of Curio's top row behave like a title bar, which it
/// covers: double-click does what System Settings › Desktop & Dock says
/// (zoom, minimise or nothing), and dragging moves the window. Buttons on the
/// row are in front of it, so they still get their own clicks.
struct TitleBarArea: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { AreaView() }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class AreaView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
      guard let window else { return }
      guard event.clickCount == 2 else {
        window.performDrag(with: event)
        return
      }
      switch Self.doubleClickAction {
      case "Minimize": window.performMiniaturize(nil)
      case "None": break
      default: window.performZoom(nil)
      }
    }

    /// The user's choice, as macOS stores it ("Maximize", "Minimize" or "None").
    private static var doubleClickAction: String {
      let defaults = UserDefaults.standard
      if let action = defaults.string(forKey: "AppleActionOnDoubleClick") { return action }
      // Older macOS kept only whether a double-click minimises.
      return defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize"
    }
  }
}
