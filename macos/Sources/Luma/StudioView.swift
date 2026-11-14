import LumaKit
import SwiftUI

/// The window: sidebar, page header, the current page and a status line.
struct StudioView: View {
  @EnvironmentObject private var studio: Studio

  var body: some View {
    HStack(spacing: 0) {
      SidebarView()
      VStack(alignment: .leading, spacing: 0) {
        header
        if let activity = studio.activity {
          ActivityBanner(activity: activity).padding(.horizontal, Theme.gutter)
            .padding(.bottom, Theme.Space.m)
        }
        page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          // On its own view: two alerts on one view can swallow each other.
          .alert("Index this folder first", isPresented: $studio.needsIndexPrompt) {
            Button("Index Now") { studio.indexFolder() }
            Button("Not Now", role: .cancel) {}
          } message: {
            Text(
              "Search and duplicate detection need a search index. Luma reads each image once and stores what it learns next to your photos. You can keep browsing while it works."
            )
          }
        statusBar
      }.background(Theme.background)
    }
    .foregroundStyle(Theme.foreground)
    .overlay {
      if let preview = studio.preview { PreviewView(state: preview) }
    }
    .tint(Theme.ink)
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

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
      VStack(alignment: .leading, spacing: Theme.Space.xs) {
        Text(title).font(.swissDisplay).lineLimit(1)
        Text(subtitle).font(.swissBody).foregroundStyle(Theme.mutedForeground).lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Button("Open Folder", action: studio.chooseFolder)
        .buttonStyle(.swissPrimary).disabled(studio.isFolderBusy)
        .help("Choose a folder of images (⌘O)")
    }
    .padding(.horizontal, Theme.gutter).padding(.top, Theme.Space.xl)
    .padding(.bottom, Theme.Space.l)
  }

  private var title: String {
    switch studio.page {
    case .library: return studio.folder?.lastPathComponent ?? "Library"
    case .duplicates: return "Duplicates"
    case .models: return "Models"
    }
  }

  private var subtitle: String {
    switch studio.page {
    case .library:
      return studio.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        ?? "No folder open"
    case .duplicates: return "Copies and near-copies in this folder."
    case .models: return "What turns your images and words into something searchable."
    }
  }

  @ViewBuilder private var page: some View {
    switch studio.page {
    case .library: LibraryView()
    case .duplicates: DuplicatesView()
    case .models: ModelsView()
    }
  }

  private var statusBar: some View {
    VStack(spacing: 0) {
      Hairline()
      HStack(spacing: Theme.Space.s) {
        if studio.activity != nil || studio.isSearching || studio.isScanning {
          ProgressView().controlSize(.small).accessibilityLabel("Working")
        }
        Text(studio.status).font(.swissCaption).foregroundStyle(Theme.mutedForeground)
          .lineLimit(1)
        Spacer()
      }
      .frame(height: Theme.Space.l)
      .padding(.horizontal, Theme.gutter).padding(.vertical, Theme.Space.s)
    }
  }
}

/// Progress for the running task: one bar from 0 to 100% with the time left.
struct ActivityBanner: View {
  /// Often enough for the bar to move smoothly between engine reports.
  private static let refresh: TimeInterval = 0.25

  @EnvironmentObject private var studio: Studio
  let activity: Activity

  var body: some View {
    TimelineView(.periodic(from: .now, by: Self.refresh)) { context in
      VStack(alignment: .leading, spacing: Theme.Space.s) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
          Text(activity.isCancelling ? "Stopping…" : activity.kind.title).font(.swissTitle)
          Spacer()
          Text(activity.detail(now: context.date)).font(.swissCaption.monospacedDigit())
            .foregroundStyle(Theme.mutedForeground)
          if activity.kind.canCancel, !activity.isFinished {
            Button(activity.kind.cancelsCooperatively ? "Pause" : "Cancel") {
              studio.cancelActivity()
            }
            .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
            .disabled(activity.isCancelling)
            .help(
              activity.kind.cancelsCooperatively
                ? "Stop after the current batch. Finished images stay searchable."
                : "Stop this task")
          }
        }
        ProgressRule(value: activity.progress(at: context.date), label: activity.kind.title)
        Text(activity.message).font(.swissCaption).foregroundStyle(Theme.mutedForeground)
      }
    }.panel(emphasis: Theme.accent)
  }
}
