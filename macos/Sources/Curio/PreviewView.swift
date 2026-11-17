import AppKit
import CurioKit
import SwiftUI

/// Full-window viewer. Arrow keys page through photos; Esc or Space closes.
struct PreviewView: View {
  private static let maxPixel = 3840

  @EnvironmentObject private var studio: Studio
  let state: PreviewState
  @State private var image: NSImage?
  @State private var originalSize: CGSize?
  @State private var failed = false
  /// The current magnification, as the zoomable image reports it.
  @State private var zoom: CGFloat = 1
  @State private var zoomRequest: ZoomRequest?
  /// The viewer's own key handling while it is open (see `listenToKeys`).
  @State private var keyMonitor: Any?

  private var photo: Photo { state.photo }

  var body: some View {
    VStack(spacing: 0) {
      topBar
      Hairline()
      ZStack {
        canvas
        HStack {
          pageButton("chevron.left", label: "Previous image", enabled: state.hasPrevious) { move(-1) }
          Spacer()
          pageButton("chevron.right", label: "Next image", enabled: state.hasNext) { move(1) }
        }.padding(.horizontal, Theme.Space.m)
      }
      Hairline()
      details
    }
    .foregroundStyle(Theme.foreground)
    .background(Theme.background)
    .onAppear(perform: listenToKeys)
    .onDisappear(perform: stopListening)
    // Photographs are judged against black, whatever the system appearance.
    .environment(\.colorScheme, .dark)
    .task(id: photo.path) { await load() }
  }

  // MARK: - Chrome

  private var topBar: some View {
    HStack(alignment: .center, spacing: Theme.Space.s) {
      VStack(alignment: .leading, spacing: 2) {
        Text(photo.name).font(.swissTitle).lineLimit(1).truncationMode(.middle)
        Text("\(Format.count(state.index + 1)) of \(Format.count(state.photos.count))")
          .font(.swissCaption.monospacedDigit()).foregroundStyle(Theme.mutedForeground)
      }
      Spacer(minLength: Theme.Space.m)
      IconButton(symbol: "minus", label: "Zoom out") {
        zoomRequest = ZoomRequest(magnification: max(ZoomableImage.range.lowerBound, zoom / 1.5))
      }.disabled(zoom <= ZoomableImage.range.lowerBound + 0.01)
      IconButton(symbol: "plus", label: "Zoom in (or double-click the image, or pinch)") {
        zoomRequest = ZoomRequest(magnification: min(ZoomableImage.range.upperBound, zoom * 1.5))
      }.disabled(zoom >= ZoomableImage.range.upperBound - 0.01)
      Button("Find Similar") { studio.searchSimilar(to: photo) }.buttonStyle(.swiss)
      Menu {
        PhotoMenu(photo: photo)
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions")
      Button("Done") { studio.preview = nil }.buttonStyle(.swissPrimary)
    }
    .padding(.horizontal, Theme.gutter).padding(.vertical, Theme.Space.m)
  }

  private var canvas: some View {
    Group {
      if let image {
        ZoomableImage(
          image: image, fileURL: photo.url, identity: photo.path, request: zoomRequest
        ) { magnification in
          // Reported from AppKit, possibly mid-update: applied on the next turn.
          DispatchQueue.main.async { zoom = magnification }
        }
        .accessibilityLabel(photo.name)
      } else if failed {
        Text("This image could not be opened.").foregroundStyle(Theme.mutedForeground)
      } else {
        ProgressView().accessibilityLabel("Loading image")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var details: some View {
    HStack(spacing: Theme.Space.m) {
      if let originalSize {
        Text("\(Int(originalSize.width)) × \(Int(originalSize.height))")
      }
      Text(Format.bytes(photo.size))
      Text(photo.modified.formatted(date: .abbreviated, time: .shortened))
      if let score = photo.score, studio.results?.showsScores == true {
        Text("\(Format.score(score)) similar").foregroundStyle(Theme.foreground)
      }
      if let tags = studio.curation?.tags(of: photo.path), !tags.isEmpty {
        Text(tags.map(\.name).joined(separator: " · ")).foregroundStyle(Theme.foreground)
          .accessibilityLabel("Tags: \(tags.map(\.name).joined(separator: ", "))")
      }
      Spacer(minLength: Theme.Space.m)
      Text((photo.path as NSString).abbreviatingWithTildeInPath).lineLimit(1)
        .truncationMode(.head).textSelection(.enabled)
    }
    .font(.swissCaption.monospacedDigit()).foregroundStyle(Theme.mutedForeground)
    .padding(.horizontal, Theme.gutter).padding(.vertical, Theme.Space.s)
  }

  private func pageButton(
    _ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: Theme.Icon.medium, weight: .semibold))
        .frame(width: 36, height: 36)
        .background(Theme.background)
        .overlay(Rectangle().strokeBorder(Theme.mutedForeground, lineWidth: Theme.hairline))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).opacity(enabled ? 1 : 0).disabled(!enabled)
    .accessibilityLabel(label).help(label)
  }

  /// ← and → page, Space and Esc close, wherever keyboard focus is. Shortcuts
  /// on hidden buttons lost these after the first move: the zoomable photo's
  /// scroll view took focus and used the arrows to scroll. Keys typed into a
  /// text field, or held with ⌘ ⌥ ⌃ ⇧, are left alone.
  private func listenToKeys() {
    guard keyMonitor == nil else { return }
    let studio = studio
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard let current = studio.preview,
        event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
        !(event.window?.firstResponder is NSText)
      else { return event }
      switch event.keyCode {
      case 123, 124:  // ← →
        let next = current.moved(by: event.keyCode == 123 ? -1 : 1)
        if next != current { studio.preview = next }
      case 49, 53:  // Space, Esc
        studio.preview = nil
      default:
        return event
      }
      return nil
    }
  }

  private func stopListening() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }

  private func move(_ offset: Int) {
    let next = state.moved(by: offset)
    if next != state { studio.preview = next }
  }

  private func load() async {
    zoom = 1
    failed = false
    originalSize = nil
    // Show the grid's thumbnail instantly, then sharpen.
    image = ImageLoader.shared.cached(photo.path, maxPixel: Thumbnail.maxPixel)
    let loaded = await ImageLoader.shared.load(photo.path, maxPixel: Self.maxPixel)
    guard !Task.isCancelled else { return }
    if let loaded {
      image = loaded.image
      originalSize = loaded.originalSize
    } else if image == nil {
      failed = true
    }
  }
}
