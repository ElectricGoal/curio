import CurioKit
import SwiftUI

/// Shown at launch while no model is installed: one choice, one download.
struct ModelSetupView: View {
  @EnvironmentObject private var studio: Studio
  @Environment(\.dismiss) private var dismiss
  @State private var choice = ModelCatalog.defaultAlias

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.l) {
      VStack(alignment: .leading, spacing: Theme.Space.s) {
        Text("Choose a search model").font(.swissHeading)
        Text(
          "Curio needs a model to search your photos by description and to find duplicates and clutter. It is downloaded once and runs entirely on this Mac — your photos never leave it."
        )
        .font(.swissBody).foregroundStyle(Theme.mutedForeground)
        .fixedSize(horizontal: false, vertical: true)
      }
      VStack(spacing: 0) {
        ForEach(studio.models) { model in
          option(model)
          if model.id != studio.models.last?.id { Hairline() }
        }
      }
      .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: Theme.hairline))
      .accessibilityElement(children: .contain).accessibilityLabel("Models")
      VStack(alignment: .leading, spacing: Theme.Space.xs) {
        if let source = studio.models.first(where: { $0.alias == choice })?.source {
          ModelSourceLine(source: source)
        }
        Text("You can switch models or remove them later in Settings (⌘,).")
          .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
      }
      HStack(spacing: Theme.Space.s) {
        Button("Not Now") {
          studio.dismissedModelSetup = true
          dismiss()
        }
        .buttonStyle(.swissQuiet).keyboardShortcut(.cancelAction)
        .help("Browse without search. Curio downloads the model when you first index a folder.")
        Spacer()
        Button("Download \(name(of: choice))") {
          studio.dismissedModelSetup = true
          studio.selectModel(choice)
          studio.downloadModel(choice)
          dismiss()
        }
        .buttonStyle(.swissPrimary).keyboardShortcut(.defaultAction)
        .disabled(!(studio.models.first { $0.alias == choice }?.available ?? false))
      }
    }
    .padding(Theme.Space.xl)
    .frame(width: 520)
    .background(Theme.background)
    .foregroundStyle(Theme.foreground)
    .tint(Theme.ink)
  }

  private func name(of alias: String) -> String {
    (studio.models.first { $0.alias == alias }?.name ?? alias)
      .replacingOccurrences(of: " (Apple)", with: "")
  }

  /// One selectable model. The choice is shown by a filled mark, weight and a rule, not colour alone.
  private func option(_ model: ModelInfo) -> some View {
    let chosen = model.alias == choice
    return Button {
      choice = model.alias
    } label: {
      HStack(alignment: .top, spacing: Theme.Space.m) {
        Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
          .font(.system(size: Theme.Icon.medium + 2)).foregroundStyle(Theme.ink)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
          HStack(spacing: Theme.Space.s) {
            Text(model.name).font(.swissTitle).fontWeight(chosen ? .bold : .semibold)
            if model.isDefault { Tag(text: "Recommended", filled: chosen) }
          }
          Text(model.summary).font(.swissCaption).foregroundStyle(Theme.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(Theme.Space.m)
      .background(chosen ? Theme.surface : .clear)
      .overlay(alignment: .leading) {
        Rectangle().fill(chosen ? Theme.ink : .clear).frame(width: Theme.rule)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(model.name)
    .accessibilityValue(model.summary)
    .accessibilityAddTraits(chosen ? [.isSelected] : [])
  }
}
