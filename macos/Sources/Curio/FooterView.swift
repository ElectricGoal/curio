import CurioKit
import SwiftUI

/// One thin line across the bottom of the window: the running task (with its
/// progress and a way to stop it) or the latest message on the left; the
/// folder, its index, the model and Settings on the right.
struct FooterView: View {
  static let height: CGFloat = 26
  /// Often enough for the bar to move smoothly between engine reports.
  private static let refresh: TimeInterval = 0.25

  @EnvironmentObject private var studio: Studio

  var body: some View {
    VStack(spacing: 0) {
      Hairline()
      HStack(spacing: Theme.Space.m) {
        if let activity = studio.activity {
          progress(activity)
        } else {
          if studio.isSearching || studio.isScanning {
            ProgressView().controlSize(.mini).accessibilityLabel("Working")
          }
          if let message = studio.footerMessage {
            Text(message).lineLimit(1).truncationMode(.tail)
          }
        }
        Spacer(minLength: Theme.Space.m)
        if let images = studio.footerImages {
          item("photo.on.rectangle", images, help: "Images in this folder")
        }
        if let index = studio.footerIndex {
          item("magnifyingglass", index, help: "What can be searched in this folder")
        }
        Button {
          studio.page = .settings
        } label: {
          Label(studio.footerModel, systemImage: "cpu").labelStyle(FooterLabelStyle())
        }
        .buttonStyle(.plain)
        .help("The search model in use. Click to change it in Settings.")
        Button {
          studio.page = .settings
        } label: {
          Image(systemName: studio.page == .settings ? "gearshape.fill" : "gearshape")
            .font(.system(size: Theme.Icon.medium, weight: .medium))
            .foregroundStyle(studio.page == .settings ? Theme.foreground : Theme.mutedForeground)
            .frame(width: 22, height: Self.height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings").help("Settings (⌘,)")
        .accessibilityAddTraits(studio.page == .settings ? .isSelected : [])
      }
      .font(.swissCaption.monospacedDigit())
      .foregroundStyle(Theme.mutedForeground)
      .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.s)
      .frame(height: Self.height)
    }
    .background(Theme.surface)
  }

  /// The running task in one line: a short bar, what it is, and how far along.
  private func progress(_ activity: Activity) -> some View {
    TimelineView(.periodic(from: .now, by: Self.refresh)) { context in
      HStack(spacing: Theme.Space.s) {
        ProgressRule(value: activity.progress(at: context.date), label: activity.kind.title)
          .frame(width: 96)
        Text(activity.isCancelling ? "Stopping…" : activity.kind.title)
          .foregroundStyle(Theme.foreground).lineLimit(1)
        Text(activity.detail(now: context.date)).lineLimit(1)
        if activity.kind.canCancel, !activity.isFinished {
          Button(activity.kind.cancelsCooperatively ? "Pause" : "Cancel") { studio.cancelActivity() }
            .buttonStyle(.plain).underline().foregroundStyle(Theme.foreground)
            .disabled(activity.isCancelling)
            .help(
              activity.kind.cancelsCooperatively
                ? "Stop after the current batch. What is finished is kept."
                : "Stop this task")
        }
        // What it is working on right now: the least important part, first to go when space is short.
        Text(activity.message).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
      }
    }
  }

  private func item(_ symbol: String, _ text: String, help: String) -> some View {
    Label(text, systemImage: symbol).labelStyle(FooterLabelStyle()).help(help)
      .accessibilityElement(children: .combine)
  }
}

/// A small symbol and its text, close together.
private struct FooterLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Theme.Space.xs) {
      configuration.icon.font(.system(size: Theme.Icon.small, weight: .medium))
      configuration.title.lineLimit(1)
    }
    .contentShape(Rectangle())
  }
}
