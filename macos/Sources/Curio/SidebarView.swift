import AppKit
import CurioKit
import SwiftUI

/// The app's name beside the window buttons, then the albums: the folders the
/// user added, any number of them. Everything about one album is in its tabs.
struct SidebarView: View {
  @EnvironmentObject private var studio: Studio

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        // On the line of the window's close, minimise and zoom buttons, just past them.
        // Just past macOS's window buttons, on their line.
        Text("Curio").font(.system(size: 15, weight: .bold))
          .frame(height: Theme.titleRow)
          .padding(.leading, Theme.windowButtonsWidth)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(TitleBarArea())
          .accessibilityAddTraits(.isHeader)
        header
        if studio.albumFolders.isEmpty {
          empty
        } else {
          ScrollView {
            VStack(spacing: 2) {
              ForEach(studio.albumFolders, id: \.self) { url in AlbumRow(url: url) }
            }
            .padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.m)
          }
          .scrollIndicators(.never)
        }
        Spacer(minLength: 0)
      }
      .frame(width: Theme.sidebarWidth, alignment: .leading)
      Rectangle().fill(Theme.border).frame(width: Theme.hairline).accessibilityHidden(true)
    }
    .background(Theme.surface)
  }

  private var header: some View {
    HStack(spacing: 0) {
      Eyebrow(text: "Albums")
      Spacer()
      IconButton(symbol: "plus", label: "Add Album… (⌘O)") { studio.chooseFolder() }
        .disabled(studio.isFolderBusy)
    }
    .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.s)
    .padding(.top, Theme.Space.l).padding(.bottom, Theme.Space.xs)
  }

  private var empty: some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      Text("Add a folder of photos to make it an album. Add as many as you like.")
        .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
        .fixedSize(horizontal: false, vertical: true)
      Button("Add Album…") { studio.chooseFolder() }
        .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
    }
    .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.xs)
  }
}

/// One album: its folder's name and how many photos it holds. The open album
/// sits in a soft card, and is marked by weight and a filled folder too, not
/// only by colour.
private struct AlbumRow: View {
  @EnvironmentObject private var studio: Studio
  let url: URL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  var body: some View {
    let selected = url == studio.folder
    let present = Studio.isDirectory(url)
    let count = studio.albumCounts[url.path]
    Button {
      studio.open(url)
    } label: {
      HStack(spacing: Theme.Space.s) {
        Image(systemName: present ? (selected ? "folder.fill" : "folder") : "externaldrive.badge.xmark")
          .font(.system(size: Theme.Icon.medium))
          .foregroundStyle(selected ? Theme.foreground : Theme.mutedForeground)
          .frame(width: 18)
        Text(url.lastPathComponent).font(.callout).fontWeight(selected ? .semibold : .regular)
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: Theme.Space.s)
        if let count {
          Text(Format.count(count)).font(.swissCaption.monospacedDigit())
            .foregroundStyle(Theme.mutedForeground)
        }
      }
      .padding(.horizontal, Theme.Space.s).frame(height: 30)
      .foregroundStyle(selected ? Theme.foreground : Theme.mutedForeground)
      .background(
        selected ? Theme.background : (hovering ? Theme.muted : .clear),
        in: RoundedRectangle(cornerRadius: Theme.controlRadius))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.controlRadius)
          .strokeBorder(selected ? Theme.border : .clear, lineWidth: Theme.hairline))
      .contentShape(Rectangle())
      .opacity(present ? 1 : 0.5)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: Theme.quick), value: hovering)
    .disabled(studio.isFolderBusy && !selected)
    .help(
      (url.path as NSString).abbreviatingWithTildeInPath + (present ? "" : " — not connected"))
    .accessibilityLabel(
      "\(url.lastPathComponent)\(count.map { ", \(Format.images($0))" } ?? "")\(present ? "" : ", not connected")"
    )
    .accessibilityAddTraits(selected ? .isSelected : [])
    .contextMenu {
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        .disabled(!present)
      Divider()
      Button("Remove from Curio") { studio.removeAlbumFolder(url) }
    }
  }
}
