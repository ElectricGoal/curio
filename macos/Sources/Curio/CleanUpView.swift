import CurioKit
import SwiftUI

/// Screenshots, blurry shots and other clutter, grouped so they can be cleared in a few clicks.
/// Nothing is chosen for removal until the user picks it: guesses are reviewed, not acted on.
struct CleanUpView: View {
  @EnvironmentObject private var studio: Studio
  @State private var confirmingTrash = false

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      if studio.folder == nil {
        message("Open a folder first", "Clean Up looks through the open folder.")
      } else if !studio.hasIndex {
        message(
          "Index this folder first",
          "Clean Up uses the search index to recognise screenshots, blurry shots and other clutter.",
          offersIndex: true)
      } else if studio.curation == nil {
        message(
          "Looking for clutter…", "This takes a few seconds the first time.", working: true)
      } else if studio.junkGroups.isEmpty {
        message(
          "Nothing to clean up",
          "No screenshots, blurry shots or other clutter stood out in this folder.")
      } else {
        summary
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(studio.junkGroups, id: \.label) { group in
              JunkSection(label: group.label, photos: group.photos)
              Hairline()
            }
          }.padding(.bottom, Theme.Space.m)
        }
      }
    }
    .padding(.horizontal, Theme.gutter)
    .confirmationDialog(
      "Move \(Format.images(studio.junkSelection.count)) to the Trash?", isPresented: $confirmingTrash
    ) {
      Button("Move to Trash", role: .destructive) { studio.moveToTrash(studio.selectedJunk) }
    } message: {
      Text("You can restore them from the Trash.")
    }
  }

  private var summary: some View {
    let selected = studio.selectedJunk
    return HStack(alignment: .center, spacing: Theme.Space.m) {
      VStack(alignment: .leading, spacing: Theme.Space.xs) {
        Text(
          selected.isEmpty
            ? "\(Format.images(studio.junkCount)) look like clutter"
            : "\(Format.count(selected.count)) selected · \(Format.bytes(selected.reduce(0) { $0 + $1.size }))"
        )
        .font(.swissTitle)
        Text("Curio’s guesses — check each group. Click the images you want to remove, then move them to the Trash.")
          .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
      }
      Spacer(minLength: Theme.Space.m)
      Button(selected.isEmpty ? "Move to Trash…" : "Move \(Format.count(selected.count)) to Trash…") {
        confirmingTrash = true
      }
      .buttonStyle(SwissButtonStyle(kind: .secondary, destructive: true))
      .disabled(selected.isEmpty || studio.activity != nil)
    }.panel(emphasis: Theme.ink)
  }

  private func message(_ title: String, _ text: String, offersIndex: Bool = false, working: Bool = false)
    -> some View
  {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      HStack(spacing: Theme.Space.s) {
        if working { ProgressView().controlSize(.small).accessibilityLabel("Working") }
        Text(title).font(.swissHeading)
      }
      Text(text).font(.swissBody).foregroundStyle(Theme.mutedForeground)
        .frame(maxWidth: 440, alignment: .leading)
      if offersIndex {
        Button("Index Now") { studio.indexFolder() }.buttonStyle(.swissPrimary)
          .disabled(studio.activity != nil).padding(.top, Theme.Space.s)
      }
    }
    .padding(.top, Theme.Space.l)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct JunkSection: View {
  private static let tile: CGFloat = 136

  @EnvironmentObject private var studio: Studio
  let label: CurationLabel
  let photos: [Photo]

  var body: some View {
    let allSelected = photos.allSatisfy { studio.junkSelection.contains($0.path) }
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
        Eyebrow(text: "\(label.name) · \(Format.count(photos.count))")
        Text(label.detail).font(.swissCaption).foregroundStyle(Theme.mutedForeground).lineLimit(1)
        Spacer()
        Button(allSelected ? "Deselect All" : "Select All") {
          studio.setJunk(photos, selected: !allSelected)
        }
        .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
      }
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: Theme.Space.m) {
          ForEach(photos) { photo in tile(photo) }
        }.padding(.bottom, Theme.Space.xs)
      }
    }.padding(.vertical, Theme.Space.m)
  }

  private func tile(_ photo: Photo) -> some View {
    let chosen = studio.junkSelection.contains(photo.path)
    return VStack(alignment: .leading, spacing: Theme.Space.xs) {
      Button {
        studio.toggleJunk(photo)
      } label: {
        Thumbnail(path: photo.path).frame(width: Self.tile, height: Self.tile)
          .overlay(Rectangle().strokeBorder(chosen ? Theme.destructive : .clear, lineWidth: Theme.rule))
          .overlay(alignment: .topLeading) {
            Image(systemName: chosen ? "checkmark.square.fill" : "square")
              .font(.system(size: Theme.Icon.medium, weight: .semibold))
              .foregroundStyle(chosen ? Theme.destructive : Theme.foreground)
              .padding(Theme.Space.xs).background(Theme.surface.opacity(0.9))
              .padding(Theme.Space.xs)
          }
      }
      .buttonStyle(.plain)
      .help(chosen ? "Click to keep this image" : "Click to move this image to the Trash")
      .accessibilityLabel("\(photo.name), \(chosen ? "selected for the Trash" : "kept")")
      .accessibilityAddTraits(chosen ? .isSelected : [])
      .contextMenu {
        Button("Quick Look") { studio.showPreview(of: photo, in: photos) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
      }
      Text(photo.name).font(.swissCaption).lineLimit(1).truncationMode(.middle)
      Text(Format.bytes(photo.size)).font(.swissCaption.monospacedDigit())
        .foregroundStyle(Theme.mutedForeground)
    }.frame(width: Self.tile, alignment: .leading)
  }
}
