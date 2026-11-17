import CurioKit
import SwiftUI

/// Review groups of copies and move the extras to the Trash.
struct DuplicatesView: View {
  @EnvironmentObject private var studio: Studio
  @State private var confirmingTrashAll = false

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      controls
      Hairline()
      if studio.folder == nil {
        message("Open a folder first", "Duplicates are found within the open folder.")
      } else if !studio.hasIndex {
        message(
          "Index this folder first",
          "Finding duplicates uses the same index as search, so nothing needs to be read twice.")
      } else if let report = studio.duplicates {
        if report.sets.isEmpty {
          message("No duplicates found", "Try a looser matching level to catch near-copies.")
        } else {
          summary(report)
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(report.sets) { set in
                DuplicateSection(set: set)
                Hairline()
              }
            }.padding(.bottom, Theme.Space.m)
          }
        }
      } else if studio.activity == nil {
        message(
          "Find copies taking up space",
          "Curio groups images that are the same picture and suggests which to keep. Nothing is removed until you say so, and removed files go to the Trash.")
      } else {
        Spacer()
      }
    }
    .padding(.horizontal, Theme.gutter)
    .confirmationDialog(
      "Move \(Format.images(studio.duplicates?.extras.count ?? 0)) to the Trash?",
      isPresented: $confirmingTrashAll
    ) {
      Button("Move to Trash", role: .destructive) {
        studio.moveToTrash(studio.duplicates?.extras ?? [])
      }
    } message: {
      Text("One image from each group is kept. You can restore the others from the Trash.")
    }
  }

  private var controls: some View {
    HStack(alignment: .center, spacing: Theme.Space.m) {
      SegmentedChoice(
        options: DuplicateMode.allCases, selection: $studio.duplicateMode, title: \.label,
        label: "Matching level")
      Text(studio.duplicateMode.explanation).font(.swissCaption)
        .foregroundStyle(Theme.mutedForeground).lineLimit(2)
      Spacer(minLength: Theme.Space.m)
      Button(studio.duplicates == nil ? "Find Duplicates" : "Search Again") {
        studio.findDuplicates()
      }
      .buttonStyle(.swissPrimary).disabled(studio.folder == nil || studio.activity != nil)
    }
  }

  private func summary(_ report: DuplicateReport) -> some View {
    HStack(alignment: .center, spacing: Theme.Space.m) {
      VStack(alignment: .leading, spacing: Theme.Space.xs) {
        Text("\(Format.count(report.sets.count)) groups · \(Format.count(report.extras.count)) extra copies")
          .font(.swissTitle)
        Text("Removing the extras frees \(Format.bytes(report.reclaimableBytes)). Click an image to mark it as the one to keep.")
          .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
      }
      Spacer(minLength: Theme.Space.m)
      Button("Move All Extras to Trash…") { confirmingTrashAll = true }
        .buttonStyle(SwissButtonStyle(kind: .secondary, destructive: true))
        .disabled(studio.activity != nil)
    }.panel(emphasis: Theme.ink)
  }

  private func message(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      Text(title).font(.swissHeading)
      Text(text).font(.swissBody).foregroundStyle(Theme.mutedForeground)
        .frame(maxWidth: 440, alignment: .leading)
      if studio.folder != nil, !studio.hasIndex {
        Button("Index Now") { studio.indexFolder() }.buttonStyle(.swissPrimary)
          .disabled(studio.activity != nil).padding(.top, Theme.Space.s)
      }
    }
    .padding(.top, Theme.Space.l)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Adjoining square buttons where exactly one option is chosen.
struct SegmentedChoice<Option: Hashable & Identifiable>: View {
  let options: [Option]
  @Binding var selection: Option
  let title: KeyPath<Option, String>
  let label: String

  var body: some View {
    // A pill track with the chosen option raised on it, as in Orca's "Names | Contents".
    HStack(spacing: 2) {
      ForEach(options) { option in
        let chosen = option == selection
        Button(option[keyPath: title]) { selection = option }
          .buttonStyle(.plain).font(.callout.weight(chosen ? .semibold : .regular))
          .padding(.horizontal, Theme.Space.m).padding(.vertical, 4)
          .foregroundStyle(chosen ? Theme.foreground : Theme.mutedForeground)
          .background(chosen ? Theme.background : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius - 1))
          .overlay(
            RoundedRectangle(cornerRadius: Theme.controlRadius - 1)
              .strokeBorder(chosen ? Theme.border : .clear, lineWidth: Theme.hairline))
          .contentShape(Rectangle())
          .accessibilityAddTraits(chosen ? .isSelected : [])
      }
    }
    .padding(2)
    .background(Theme.muted, in: RoundedRectangle(cornerRadius: Theme.controlRadius + 1))
    .fixedSize()
    .accessibilityElement(children: .contain).accessibilityLabel(label)
  }
}

private struct DuplicateSection: View {
  private static let tile: CGFloat = 152

  @EnvironmentObject private var studio: Studio
  let set: DuplicateSet

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      HStack(alignment: .firstTextBaseline) {
        Eyebrow(text: set.label)
        Spacer()
        Button("Move \(Format.count(set.extras.count)) to Trash") { studio.moveToTrash(set.extras) }
          .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
          .disabled(studio.activity != nil)
      }
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: Theme.Space.m) {
          ForEach(set.photos) { photo in tile(photo) }
        }.padding(.bottom, Theme.Space.xs)
      }
    }.padding(.vertical, Theme.Space.m)
  }

  private func tile(_ photo: Photo) -> some View {
    let kept = photo.path == set.keeperPath
    return VStack(alignment: .leading, spacing: Theme.Space.xs) {
      Button {
        studio.keep(photo, in: set)
      } label: {
        Thumbnail(path: photo.path).frame(width: Self.tile, height: Self.tile)
          .opacity(kept ? 1 : 0.5)
          // The copy to keep is outlined and labelled; the label carries the meaning.
          .overlay(Rectangle().strokeBorder(kept ? Theme.ink : .clear, lineWidth: Theme.rule))
          .overlay(alignment: .topLeading) { Tag(text: kept ? "Keep" : "Trash", filled: kept) }
      }
      .buttonStyle(.plain)
      .help(kept ? "This copy is kept" : "Click to keep this copy instead")
      .accessibilityLabel("\(photo.name), \(kept ? "kept" : "will be moved to the Trash")")
      .contextMenu {
        Button("Quick Look") { studio.showPreview(of: photo, in: set.photos) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
      }
      Text(photo.name).font(.swissCaption).lineLimit(1).truncationMode(.middle)
      HStack(spacing: Theme.Space.s) {
        Text(Format.bytes(photo.size)).monospacedDigit().foregroundStyle(Theme.mutedForeground)
        if photo.path == set.bestShotPath {
          Label("Best shot", systemImage: "sparkles").labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.foreground)
            .help("The sharpest, best-composed photo of this group")
        }
      }.font(.swissCaption)
    }.frame(width: Self.tile, alignment: .leading)
  }
}
