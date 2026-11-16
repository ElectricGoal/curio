import CurioKit
import SwiftUI

/// The Settings page: how the app looks, and the models it runs.
struct SettingsView: View {
  @EnvironmentObject private var studio: Studio

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Eyebrow(text: "Appearance").padding(.bottom, Theme.Space.s)
        HStack(spacing: Theme.Space.m) {
          SegmentedChoice(
            options: Appearance.allCases,
            selection: Binding(get: { studio.appearance }, set: { studio.setAppearance($0) }),
            title: \.label, label: "Appearance")
          Text(explanation).font(.swissCaption).foregroundStyle(Theme.mutedForeground)
        }
        Eyebrow(text: "Models").padding(.top, Theme.Space.xl).padding(.bottom, Theme.Space.s)
        ModelsView()
      }
      .padding(.horizontal, Theme.gutter).padding(.bottom, Theme.Space.l)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var explanation: String {
    switch studio.appearance {
    case .system: return "Follows your Mac: light or dark as set in System Settings."
    case .light: return "Always light, whatever your Mac is set to."
    case .dark: return "Always dark, whatever your Mac is set to."
    }
  }
}
