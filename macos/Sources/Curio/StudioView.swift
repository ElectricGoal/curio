import CurioKit
import SwiftUI

/// The window: sidebar, page header and the current page, over a footer.
struct StudioView: View {
  @EnvironmentObject private var studio: Studio

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
      if let preview = studio.preview { PreviewView(state: preview) }
    }
    .tint(Theme.ink)
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
        page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    case .cleanup: return "Clean Up"
    case .filter: return "Filter"
    case .settings: return "Settings"
    }
  }

  private var subtitle: String {
    switch studio.page {
    case .library:
      return studio.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        ?? "No folder open"
    case .duplicates: return "Copies and near-copies in this folder."
    case .cleanup: return "Screenshots, blurry shots and other clutter in this folder."
    case .filter: return "Keep and remove images step by step, then copy or move what is left."
    case .settings: return "How Curio looks, and the models it runs on this Mac."
    }
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
