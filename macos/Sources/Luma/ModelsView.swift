import AppKit
import LumaKit
import SwiftUI

/// Download, choose and remove the models that power search.
struct ModelsView: View {
  @EnvironmentObject private var studio: Studio
  @State private var deleting: ModelInfo?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Text(
          "A model turns images and words into something comparable. It runs on this Mac, so your images are never sent anywhere. Each folder remembers the model it was indexed with."
        )
        .font(.swissBody).foregroundStyle(Theme.mutedForeground)
        .frame(maxWidth: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, Theme.Space.l)
        Hairline()
        ForEach(studio.models) { model in
          row(model)
          Hairline()
        }
        if studio.models.isEmpty {
          HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small)
            Text("Loading models…").foregroundStyle(Theme.mutedForeground)
          }.padding(.vertical, Theme.Space.l)
        } else if let storage = studio.modelStorage {
          HStack(spacing: Theme.Space.s) {
            Text("Stored in \((storage as NSString).abbreviatingWithTildeInPath)")
              .font(.swissCaption).foregroundStyle(Theme.mutedForeground).lineLimit(1)
              .truncationMode(.middle)
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: storage)])
            }.buttonStyle(SwissButtonStyle(kind: .quiet, compact: true))
          }.padding(.top, Theme.Space.m)
        }
      }
      .padding(.horizontal, Theme.gutter).padding(.bottom, Theme.Space.l)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear { if studio.models.isEmpty { studio.refreshModels() } }
    .confirmationDialog(
      "Remove \(deleting?.name ?? "this model")?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { model in
      Button("Remove \(Format.bytes(model.size))", role: .destructive) { studio.deleteModel(model.alias) }
    } message: { _ in
      Text("You can download it again later. Your photos and their indexes are kept, but folders indexed with this model cannot be searched until it is back.")
    }
  }

  private func row(_ model: ModelInfo) -> some View {
    let selected = studio.selectedModel == model.alias
    let usedHere = studio.indexStatus?.indexed == true && studio.indexStatus?.model == model.alias
    return HStack(alignment: .top, spacing: Theme.Space.l) {
      VStack(alignment: .leading, spacing: Theme.Space.xs) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
          Text(model.name).font(.swissTitle)
          if selected { Tag(text: "Selected", filled: true) }
          if usedHere { Tag(text: "Used by this folder") }
        }
        Text(model.summary).font(.swissBody).foregroundStyle(Theme.mutedForeground)
          .frame(maxWidth: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        Text(stateLine(model)).font(.swissCaption.monospacedDigit())
          .foregroundStyle(model.installed ? Theme.foreground : Theme.mutedForeground)
        if !model.availabilityMessage.isEmpty {
          Text(model.availabilityMessage).font(.swissCaption).foregroundStyle(Theme.destructive)
            .textSelection(.enabled)
        }
      }
      Spacer(minLength: Theme.Space.m)
      HStack(spacing: Theme.Space.s) {
        if !model.installed {
          Button("Download") { studio.downloadModel(model.alias) }
            .buttonStyle(.swissPrimary).disabled(!model.available || studio.activity != nil)
        }
        if !selected {
          Button("Select") { studio.selectModel(model.alias) }.buttonStyle(.swiss)
            .disabled(!model.available)
            .help("Use this model for new indexes and rebuilds")
        }
        if model.size > 0 {
          Button("Remove") { deleting = model }
            .buttonStyle(SwissButtonStyle(kind: .quiet, destructive: true))
            .disabled(studio.activity != nil).help("Remove this model's files")
        }
      }
    }
    .padding(.vertical, Theme.Space.m).padding(.leading, Theme.Space.m)
    // The selected model is marked by a rule and a tag, not by colour alone.
    .overlay(alignment: .leading) {
      Rectangle().fill(selected ? Theme.ink : .clear).frame(width: Theme.rule)
    }
  }

  private func stateLine(_ model: ModelInfo) -> String {
    if model.installed {
      // Models inside the app take no space the user could free.
      return model.size > 0 ? "Installed · \(Format.bytes(model.size))" : "Included with the app"
    }
    if model.size > 0 { return "Partly downloaded · \(Format.bytes(model.size))" }
    return "Not installed"
  }
}
