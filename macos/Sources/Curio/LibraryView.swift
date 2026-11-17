import CurioKit
import SwiftUI

/// Browse and search the open folder.
struct LibraryView: View {
  @EnvironmentObject private var studio: Studio
  @FocusState private var searchFocused: Bool
  @State private var confirmingRebuild = false

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      if studio.folder == nil {
        welcome
      } else {
        banners
        searchBar
        tagRow
        toolbar
        Hairline()
        content
      }
    }
    .padding(.horizontal, Theme.gutter)
    .onChange(of: studio.searchFocusRequests) { searchFocused = true }
    .confirmationDialog("Rebuild this folder’s search index?", isPresented: $confirmingRebuild) {
      Button("Rebuild with \(studio.selectedModelName)") { studio.indexFolder(rebuild: true) }
    } message: {
      Text(
        "Every image is read again using \(studio.selectedModelName). Your photos are not changed, and the current index is kept if you cancel."
      )
    }
  }

  // MARK: - Banners

  /// At most one banner, most actionable first.
  @ViewBuilder private var banners: some View {
    if studio.activity == nil {
      if let problem = studio.engineProblem {
        banner(
          title: "Search is unavailable", tone: Theme.destructive,
          message: problem,
          action: ("Try Again", { studio.refreshIndexStatus(preparingSearch: true) }))
      } else if let notice = studio.notice, notice.offersResume {
        noticeBanner(notice)
      } else if let status = studio.indexStatus, !status.indexed, status.total > 0 {
        banner(
          title: "Index this folder to search it",
          message:
            "Curio reads each image once so you can search by description or by example. You can keep browsing meanwhile.",
          action: ("Index Now", { studio.indexFolder() }))
      } else if studio.indexNeedsRebuild {
        banner(
          title: "This folder needs a new index",
          message:
            (studio.indexStatus?.rebuildReason ?? "Its index cannot be used by this version.")
            + " Rebuilding reads every image again with \(studio.selectedModelName).",
          action: ("Rebuild Index", { studio.indexFolder(rebuild: true) }))
      } else if let status = studio.indexStatus, status.indexed, status.pending > 0 {
        banner(
          title: "\(Format.images(status.pending)) not searchable yet",
          message: "New or changed since the last index. Updating only reads those files.",
          action: ("Update Index", { studio.indexFolder() }))
      } else if let notice = studio.notice {
        noticeBanner(notice)
      } else if studio.indexUsesOtherModel, !studio.dismissedModelHint {
        banner(
          title: "Indexed with \(studio.indexStatus?.modelName ?? "another model")",
          message: "Search keeps using it. Rebuild to switch this folder to \(studio.selectedModelName).",
          action: ("Rebuild…", { confirmingRebuild = true }),
          dismiss: { studio.dismissedModelHint = true })
      }
    }
  }

  private func noticeBanner(_ notice: Notice) -> some View {
    banner(
      title: notice.title, message: notice.message,
      action: notice.offersResume ? ("Resume", { studio.indexFolder() }) : nil,
      dismiss: { studio.notice = nil })
  }

  /// One message with at most one action. `tone` colours the leading rule.
  private func banner(
    title: String, tone: Color = Theme.ink, message: String,
    action: (label: String, run: () -> Void)? = nil, dismiss: (() -> Void)? = nil
  ) -> some View {
    HStack(alignment: .center, spacing: Theme.Space.m) {
      VStack(alignment: .leading, spacing: Theme.Space.xs) {
        Text(title).font(.swissTitle)
        Text(message).font(.swissCaption).foregroundStyle(Theme.mutedForeground)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      Spacer(minLength: Theme.Space.m)
      if let action { Button(action.label, action: action.run).buttonStyle(.swiss) }
      if let dismiss { IconButton(symbol: "xmark", label: "Dismiss", action: dismiss) }
    }.panel(emphasis: tone)
  }

  // MARK: - Search

  private var searchBar: some View {
    HStack(spacing: Theme.Space.s) {
      Image(systemName: "magnifyingglass").font(.system(size: Theme.Icon.medium))
        .foregroundStyle(Theme.mutedForeground).accessibilityHidden(true)
      if let reference = studio.reference { referenceChip(reference) }
      TextField(searchPrompt, text: $studio.query)
        .textFieldStyle(.plain).font(.title3).focused($searchFocused)
        .onSubmit { studio.submitSearch() }
        .onChange(of: studio.query) { studio.queryEdited() }
        .onExitCommand { studio.clearSearch() }
        .accessibilityLabel("Search this folder")
      if studio.isSearching {
        ProgressView().controlSize(.small).accessibilityLabel("Searching")
      }
      if !studio.query.isEmpty || studio.results != nil {
        IconButton(symbol: "xmark", label: "Clear search (Esc)") { studio.clearSearch() }
      }
      Rectangle().fill(Theme.border).frame(width: Theme.hairline, height: 18)
        .accessibilityHidden(true)
      IconButton(
        symbol: "photo", label: "Search with an image, or drop one anywhere in the window",
        action: studio.chooseReferenceImage
      ).disabled(studio.activity != nil)
    }
    .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
    // Drawn inside the frame, so focus thickens the edge without moving anything.
    .overlay(
      RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(
        searchFocused ? Theme.ink : Theme.mutedForeground,
        lineWidth: searchFocused ? Theme.rule : Theme.hairline))
  }

  /// The image a search by example started from; typing then refines it.
  private func referenceChip(_ reference: ReferenceImage) -> some View {
    HStack(spacing: Theme.Space.xs) {
      Thumbnail(path: reference.path).frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: Theme.tagRadius))
      Text(reference.name).font(.callout).lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: 160, alignment: .leading)
    }
    .padding(.trailing, Theme.Space.s)
    .overlay(RoundedRectangle(cornerRadius: Theme.tagRadius).strokeBorder(Theme.border, lineWidth: Theme.hairline))
    .help("Searching by this image. Type words to steer the results.")
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Searching by example: \(reference.name)")
  }

  private var searchPrompt: String {
    if studio.reference != nil { return "Refine — “at night”, or “-people” to leave out" }
    if studio.engineProblem != nil { return "Search is unavailable — see the note above" }
    if studio.isFolderBusy { return "Search is available when the current task finishes" }
    if studio.indexNeedsRebuild { return "Rebuild this folder’s index to search it" }
    return studio.hasIndex
      ? "Describe an image — a quiet beach at sunset"
      : "Index this folder to search by description"
  }

  // MARK: - Tags

  private static let visibleTags = 10

  /// Saved searches first, then the folder's most common tags; choosing one
  /// shows only its photos, choosing it again shows them all.
  @ViewBuilder private var tagRow: some View {
    let tags = studio.folderTags
    if !tags.isEmpty || !studio.savedSearches.isEmpty {
      FlowLayout {
        ForEach(studio.savedSearches, id: \.self) { name in
          let label = Labels.album(name)
          Chip(
            title: name, count: studio.curation.map { $0.count(for: label) },
            selected: studio.results?.label == label, symbol: "bookmark"
          ) {
            studio.showSavedSearch(name)
          }
          .contextMenu { Button("Remove Saved Search") { studio.removeSavedSearch(name) } }
          .help("A saved search: it updates itself as you add photos. Right-click to remove it.")
        }
        ForEach(tags.prefix(Self.visibleTags), id: \.label) { tag in
          Chip(title: tag.label.name, count: tag.count, selected: studio.results?.label == tag.label) {
            studio.show(tag.label)
          }
        }
        if tags.count > Self.visibleTags {
          Menu("\(tags.count - Self.visibleTags) more") {
            ForEach(tags.dropFirst(Self.visibleTags), id: \.label) { tag in
              Button("\(tag.label.name)  \(Format.count(tag.count))") { studio.show(tag.label) }
            }
          }
          .menuStyle(.borderlessButton).fixedSize().font(.callout)
          .accessibilityLabel("More tags")
        }
      }
      .accessibilityElement(children: .contain).accessibilityLabel("Tags")
    } else if studio.isCurating, studio.curation == nil {
      Text("Tagging your photos…").font(.swissCaption).foregroundStyle(Theme.mutedForeground)
    }
  }

  // MARK: - Toolbar

  private var toolbar: some View {
    HStack(alignment: .center, spacing: Theme.Space.m) {
      if let results = studio.results {
        Eyebrow(text: "Results")
        Text(results.title).font(.callout.weight(.medium)).lineLimit(1)
        Text(
          results.isRanked
            ? "\(Format.count(results.photos.count)), closest first" : Format.images(results.photos.count)
        )
        .font(.swissCaption.monospacedDigit()).foregroundStyle(Theme.mutedForeground)
        Button("Show All") { studio.clearSearch() }
          .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
        if results.kind == .text {
          Button("Save Search") { studio.saveSearch() }
            .buttonStyle(SwissButtonStyle(kind: .quiet, compact: true))
            .help("Keep this search as a chip above. It updates itself as you add photos.")
        }
      } else {
        Eyebrow(text: "Collection")
        Text(Format.count(studio.isScanning ? studio.scanCount : studio.library.count))
          .font(.swissCaption.monospacedDigit()).foregroundStyle(Theme.mutedForeground)
      }
      Spacer()
      if studio.results == nil {
        Menu {
          Picker("Sort", selection: $studio.sort) {
            ForEach(PhotoSort.allCases) { Text($0.label).tag($0) }
          }.pickerStyle(.inline).labelsHidden()
        } label: {
          Text("Sort: \(studio.sort.label)").font(.callout)
        }
        .menuStyle(.borderlessButton).fixedSize().help("Sort order")
      }
      Slider(
        value: $studio.thumbnailSize, in: Preferences.thumbnailRange,
        onEditingChanged: { editing in if !editing { studio.saveThumbnailSize() } }
      )
      .frame(width: 96).controlSize(.small)
      .accessibilityLabel("Thumbnail size").help("Thumbnail size")
      Button(studio.hasIndex ? "Update Index" : "Index for Search") { studio.indexFolder() }
        .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
        .disabled(studio.activity != nil || studio.isFolderBusy)
        .help("Make new and changed images searchable (⌘U)")
      Menu {
        Button("Reload Folder") { studio.reloadLibrary() }
        Button("Show Folder in Finder") { studio.revealFolder() }
        Divider()
        Button("Rebuild Index with \(studio.selectedModelName)…") { confirmingRebuild = true }
          .disabled(studio.activity != nil)
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions")
    }
  }

  // MARK: - Content

  @ViewBuilder private var content: some View {
    let photos = studio.visiblePhotos
    if !photos.isEmpty {
      PhotoGrid(
        photos: photos, thumbnailSize: studio.thumbnailSize,
        showsScores: studio.results?.showsScores ?? false
      ) { photo in
        studio.showPreview(of: photo, in: photos)
      }.equatable()
    } else if studio.isScanning {
      emptyState(
        title: "Reading your library…",
        message: studio.scanCount > 0 ? "\(Format.images(studio.scanCount)) so far" : "")
    } else if let results = studio.results, !results.isRanked {
      emptyState(
        title: "Nothing here yet",
        message: "Photos matching “\(results.title)” appear here once they are indexed.")
    } else if studio.results != nil {
      emptyState(
        title: "No matches",
        message: "Try describing the scene, colours or subject differently.")
    } else {
      emptyState(
        title: "No images in this folder",
        message: "Curio shows JPEG, PNG, HEIC, WebP, TIFF, BMP and GIF files, including those in subfolders.")
    }
  }

  /// Set flush left on the page margin, like everything else.
  private func emptyState(title: String, message: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      Text(title).font(.swissHeading)
      Text(message).font(.swissBody).foregroundStyle(Theme.mutedForeground)
        .frame(maxWidth: 440, alignment: .leading)
    }
    .padding(.top, Theme.Space.l)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var welcome: some View {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
      Image(systemName: "photo.stack").font(.system(size: 40, weight: .light))
        .foregroundStyle(Theme.mutedForeground).accessibilityHidden(true)
      Text("Add your first album").font(.title.weight(.semibold))
      Text("An album is a folder of photos. Add as many as you like, then search each by description, find duplicates, clean up clutter and filter in steps. Drop folders anywhere in this window, or use + in the sidebar. Nothing leaves your Mac.")
        .font(.swissBody).foregroundStyle(Theme.mutedForeground)
        .frame(maxWidth: 460, alignment: .leading)
      Button("Add Album…", action: studio.chooseFolder).buttonStyle(.swissPrimary)
        .padding(.top, Theme.Space.s)
    }
    .padding(.top, Theme.Space.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
