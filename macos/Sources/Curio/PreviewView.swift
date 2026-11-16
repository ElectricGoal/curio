import AppKit
import CurioKit
import SwiftUI

/// Full-window viewer. Arrow keys page through photos; Esc or Space closes.
struct PreviewView: View {
  private static let maxPixel = 3840
  private static let zoomRange: ClosedRange<CGFloat> = 1...6

  @EnvironmentObject private var studio: Studio
  let state: PreviewState
  @State private var image: NSImage?
  @State private var originalSize: CGSize?
  @State private var failed = false
  @State private var zoom: CGFloat = 1

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
    .background(shortcuts)
    // Photographs are judged against black, whatever the system appearance.
    .environment(\.colorScheme, .dark)
    .task(id: photo.path) { await load() }
    .transition(.opacity)
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
        zoom = max(Self.zoomRange.lowerBound, zoom / 1.5)
      }.disabled(zoom <= Self.zoomRange.lowerBound)
      IconButton(symbol: "plus", label: "Zoom in (or double-click the image)") {
        zoom = min(Self.zoomRange.upperBound, zoom * 1.5)
      }.disabled(zoom >= Self.zoomRange.upperBound)
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
    GeometryReader { area in
      ScrollView([.horizontal, .vertical]) {
        Group {
          if let image {
            Image(nsImage: image).resizable().scaledToFit()
              .onTapGesture(count: 2) { zoom = zoom > 1 ? 1 : 2.5 }
              .draggable(photo.url)
              .accessibilityLabel(photo.name)
          } else if failed {
            Text("This image could not be opened.").foregroundStyle(Theme.mutedForeground)
          } else {
            ProgressView().accessibilityLabel("Loading image")
          }
        }
        .frame(width: area.size.width * zoom, height: area.size.height * zoom)
      }
      .scrollIndicators(zoom > 1 ? .automatic : .hidden)
    }
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

  /// Invisible buttons that give the viewer its keyboard shortcuts.
  private var shortcuts: some View {
    Group {
      Button("Previous") { move(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
      Button("Next") { move(1) }.keyboardShortcut(.rightArrow, modifiers: [])
      Button("Close") { studio.preview = nil }.keyboardShortcut(.cancelAction)
      Button("Close") { studio.preview = nil }.keyboardShortcut(.space, modifiers: [])
    }.opacity(0).accessibilityHidden(true)
  }

  // MARK: - Behaviour

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
