import AppKit
import CurioKit
import SwiftUI

/// A scrolling grid of photos. Click to view, right-click for more.
///
/// Deliberately does not observe the app state: with tens of thousands of
/// photos, re-diffing the grid on every progress tick or status change would
/// make the whole window stutter. It redraws only when its own inputs change.
struct PhotoGrid: View, Equatable {
  let photos: [Photo]
  let thumbnailSize: Double
  var showsScores = false
  let open: (Photo) -> Void

  static func == (lhs: PhotoGrid, rhs: PhotoGrid) -> Bool {
    lhs.thumbnailSize == rhs.thumbnailSize && lhs.showsScores == rhs.showsScores
      && lhs.photos == rhs.photos
  }

  var body: some View {
    ScrollView {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: Theme.Space.m)],
        alignment: .leading, spacing: Theme.Space.l
      ) {
        ForEach(photos) { photo in
          PhotoCell(photo: photo, score: showsScores ? photo.score : nil) { open(photo) }
            .contextMenu { PhotoMenu(photo: photo) }
        }
      }
      .padding(.top, Theme.Space.s).padding(.bottom, Theme.Space.m)
    }
  }
}

/// A square image on the grid with its name beneath.
struct PhotoCell: View {
  let photo: Photo
  let score: Double?
  let open: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: Theme.Space.s) {
        Thumbnail(path: photo.path).aspectRatio(1, contentMode: .fit)
          .overlay(
            Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.rule).opacity(hovering ? 1 : 0))
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
          Text(photo.name).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(hovering ? Theme.foreground : Theme.mutedForeground)
          Spacer(minLength: 0)
          if let score {
            Text(Format.score(score)).foregroundStyle(Theme.accent).monospacedDigit()
              .help("How similar this image is to the one you searched with")
          }
        }.font(.swissCaption)
      }.contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: Theme.quick), value: hovering)
    .draggable(photo.url)
    .accessibilityLabel("Preview \(photo.name)")
  }
}

/// Actions shared by the grid's context menu and the viewer.
struct PhotoMenu: View {
  @EnvironmentObject private var studio: Studio
  let photo: Photo

  var body: some View {
    Button("Find Similar") { studio.searchSimilar(to: photo) }
    Divider()
    Button("Open") { NSWorkspace.shared.open(photo.url) }
    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
    Divider()
    Button("Copy Image") { PhotoActions.copyImage(photo) }
    Button("Copy Path") { PhotoActions.copyPath(photo) }
    Divider()
    Button("Move to Trash") { studio.moveToTrash([photo]) }
  }
}

enum PhotoActions {
  /// Puts the file on the pasteboard, so it pastes as an image or an attachment.
  static func copyImage(_ photo: Photo) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([photo.url as NSURL])
  }

  static func copyPath(_ photo: Photo) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(photo.path, forType: .string)
  }
}
