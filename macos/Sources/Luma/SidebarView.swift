import LumaKit
import SwiftUI

/// Navigation, recent folders and the state of the index, in one column.
struct SidebarView: View {
  @EnvironmentObject private var studio: Studio

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: Theme.Space.xl) {
        Text("Luma").font(.swissHeading.weight(.bold)).padding(.horizontal, Theme.Space.m)
          .padding(.top, Theme.Space.xl)
        VStack(spacing: 0) {
          ForEach(Page.allCases) { page in navigation(page) }
        }
        if !studio.recentFolders.isEmpty { recents }
        Spacer(minLength: 0)
        indexSummary
      }
      .frame(width: Theme.sidebarWidth, alignment: .leading)
      Rectangle().fill(Theme.border).frame(width: Theme.hairline).accessibilityHidden(true)
    }
    .background(Theme.surface)
  }

  private func navigation(_ page: Page) -> some View {
    let badge: String? = {
      guard page == .duplicates, let extras = studio.duplicates?.extras.count, extras > 0 else {
        return nil
      }
      return Format.count(extras)
    }()
    return SidebarRow(title: page.title, selected: studio.page == page, trailing: badge) {
      studio.page = page
      if page == .models { studio.refreshModels() }
    }
  }

  private var recents: some View {
    VStack(alignment: .leading, spacing: 0) {
      Eyebrow(text: "Recent").padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s)
      ForEach(studio.recentFolders.prefix(6), id: \.self) { url in
        let current = url == studio.folder
        SidebarRow(title: url.lastPathComponent, selected: current, compact: true) {
          studio.open(url)
        }
        .disabled(studio.isFolderBusy && !current)
        .help((url.path as NSString).abbreviatingWithTildeInPath)
        .contextMenu {
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          Button("Remove from Recents") { studio.forget(url) }
        }
      }
    }
  }

  /// What is searchable right now, at a glance.
  private var indexSummary: some View {
    VStack(alignment: .leading, spacing: 0) {
      Hairline()
      VStack(alignment: .leading, spacing: Theme.Space.xs) {
        Eyebrow(text: "Index")
        Text(headline).font(.swissTitle)
        Text(detail).font(.swissCaption).foregroundStyle(Theme.mutedForeground)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var headline: String {
    guard studio.folder != nil else { return "Private by design" }
    if studio.engineProblem != nil { return "Search unavailable" }
    guard let status = studio.indexStatus else { return "Checking index…" }
    if status.needsRebuild { return "Index out of date" }
    return status.indexed ? "\(Format.count(status.count)) searchable" : "Not indexed yet"
  }

  private var detail: String {
    guard studio.folder != nil else { return "Your images never leave this Mac." }
    if studio.engineProblem != nil { return "You can still browse. See the note in the library." }
    guard let status = studio.indexStatus else { return "Reading the folder." }
    guard status.indexed else { return "Index this folder to search it by meaning." }
    if status.needsRebuild { return "Rebuild it to search this folder again." }
    var lines = [status.modelName ?? "Indexed"]
    if status.pending > 0 { lines.append("\(Format.count(status.pending)) new to index") }
    return lines.joined(separator: "\n")
  }
}

/// One line of the sidebar. The current row is marked by weight and a rule,
/// not by colour alone.
private struct SidebarRow: View {
  let title: String
  let selected: Bool
  var trailing: String?
  var compact = false
  let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 0) {
        Rectangle().fill(selected ? Theme.ink : .clear).frame(width: Theme.rule)
        Text(title).font(compact ? .callout : .body).fontWeight(selected ? .semibold : .regular)
          .lineLimit(1).truncationMode(.middle)
          .padding(.leading, Theme.Space.m - Theme.rule)
        Spacer(minLength: Theme.Space.s)
        if let trailing {
          Text(trailing).font(.swissCaption.monospacedDigit())
            .foregroundStyle(Theme.mutedForeground).padding(.trailing, Theme.Space.m)
        }
      }
      .frame(height: compact ? 28 : 34)
      .foregroundStyle(selected ? Theme.foreground : Theme.mutedForeground)
      .background(hovering && isEnabled ? Theme.muted : .clear)
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.4)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: Theme.quick), value: hovering)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
