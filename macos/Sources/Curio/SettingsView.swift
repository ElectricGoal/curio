import CurioKit
import SwiftUI

/// Curio › Settings… (⌘,): the search models, with download progress shown here too.
struct SettingsView: View {
  @EnvironmentObject private var studio: Studio

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Models").font(.swissDisplay)
        .padding(.horizontal, Theme.gutter).padding(.top, Theme.Space.l).padding(.bottom, Theme.Space.m)
      if let activity = studio.activity, case .downloading = activity.kind {
        ActivityBanner(activity: activity).padding(.horizontal, Theme.gutter)
          .padding(.bottom, Theme.Space.m)
      }
      ModelsView()
    }
    .frame(width: 680, height: 500, alignment: .topLeading)
    .background(Theme.background)
    .foregroundStyle(Theme.foreground)
    .tint(Theme.ink)
    .onAppear { studio.refreshModels() }
  }
}
