import CurioKit
import SwiftUI

/// A chain of steps, top to bottom: all images → each keep/remove step → the result,
/// which is copied or moved to a folder. The right side previews any node.
struct FilterView: View {
  private static let chainWidth: CGFloat = 440

  @EnvironmentObject private var studio: Studio
  @State private var confirmingMove = false

  var body: some View {
    Group {
      if studio.folder == nil {
        message("Open a folder first", "The filter runs over the open folder.")
      } else if !studio.hasIndex {
        message(
          "Index this folder first",
          "Filter steps compare your descriptions with the search index.", offersIndex: true)
      } else {
        HStack(alignment: .top, spacing: 0) {
          ScrollView {
            chain.padding(.trailing, Theme.Space.m).padding(.bottom, Theme.Space.l)
          }
          .frame(width: Self.chainWidth)
          Rectangle().fill(Theme.border).frame(width: Theme.hairline).accessibilityHidden(true)
          preview.padding(.leading, Theme.Space.l)
        }
      }
    }
    .padding(.horizontal, Theme.gutter)
    .onAppear { if studio.filterRun == nil { studio.runFilter(immediately: true) } }
    .confirmationDialog(
      "Move \(Format.images(studio.filterRun?.result.count ?? 0)) out of this folder?",
      isPresented: $confirmingMove
    ) {
      Button("Move to \(studio.exportFolder?.lastPathComponent ?? "folder")") { studio.exportFiltered() }
    } message: {
      Text("They leave this folder and its index. Files with the same name in the destination are kept; moved ones get a number added.")
    }
  }

  // MARK: - Chain

  private var chain: some View {
    VStack(alignment: .leading, spacing: 0) {
      startNode
      ForEach(Array(studio.filterSteps.enumerated()), id: \.element.id) { index, step in
        Connector()
        StepNode(step: step, index: index, isLast: index == studio.filterSteps.count - 1)
      }
      Connector()
      addRow
      Connector()
      resultNode
    }
  }

  private var startNode: some View {
    VStack(alignment: .leading, spacing: Theme.Space.xs) {
      Eyebrow(text: "Start")
      Text("All \(Format.images(studio.filterRun?.all.count ?? studio.library.count))")
        .font(.swissTitle)
      Text("Each step below keeps or removes images, then passes the rest on.")
        .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .panel()
  }

  private var addRow: some View {
    HStack(spacing: Theme.Space.s) {
      Button("+ Keep Step") { studio.addStep(.keep) }
        .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
        .help("Keep only images that match a description")
      Button("+ Remove Step") { studio.addStep(.remove) }
        .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
        .help("Take out images that match a description")
      Menu("Suggestions") {
        ForEach(Studio.suggestedSteps, id: \.text) { suggestion in
          Button("\(suggestion.action.label): \(suggestion.text)") {
            studio.addStep(suggestion.action, text: suggestion.text)
          }
        }
      }
      .menuStyle(.borderlessButton).fixedSize().font(.callout)
      .accessibilityLabel("Add a suggested step")
    }
  }

  private var resultNode: some View {
    let run = studio.filterRun
    let count = run?.result.count ?? 0
    let focused = studio.filterFocus == nil
    return VStack(alignment: .leading, spacing: Theme.Space.m) {
      HStack(spacing: Theme.Space.s) {
        Eyebrow(text: "Result")
        if let traced = studio.filterTraced, let run {
          let inResult = run.result.contains(traced)
          TraceMark(text: inResult ? "In the result" : "Not in the result", passed: inResult)
        }
        Spacer()
        if studio.isFiltering { ProgressView().controlSize(.small).accessibilityLabel("Filtering") }
      }
      Text(run == nil ? "Filtering…" : Format.images(count)).font(.swissHeading)
        .contentTransition(.numericText())
      Hairline()
      VStack(alignment: .leading, spacing: Theme.Space.s) {
        Eyebrow(text: "Send to")
        HStack(spacing: Theme.Space.s) {
          Button(studio.exportFolder == nil ? "Choose Folder…" : "Change…") { studio.chooseExportFolder() }
            .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
          Button("New Folder…") { studio.createExportFolder() }
            .buttonStyle(SwissButtonStyle(kind: .quiet, compact: true))
            .help("Create a new folder for the filtered images")
        }
        if let destination = studio.exportFolder {
          Label((destination.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
            .font(.swissCaption).lineLimit(1).truncationMode(.head)
            .help(destination.path)
        }
        HStack(spacing: Theme.Space.m) {
          SegmentedChoice(
            options: FileExport.Mode.allCases, selection: $studio.exportMode, title: \.label,
            label: "Copy or move")
          Text(studio.exportMode == .copy ? "The originals stay here." : "The originals leave this folder.")
            .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
        }
      }
      Button("\(studio.exportMode.label) \(Format.images(count))") {
        if studio.exportMode == .move { confirmingMove = true } else { studio.exportFiltered() }
      }
      .buttonStyle(.swissPrimary)
      .disabled(
        studio.exportFolder == nil || count == 0 || studio.activity != nil || studio.isFiltering)
      .help(studio.exportFolder == nil ? "Choose a folder first" : "")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .panel(emphasis: focused ? Theme.ink : nil)
    .contentShape(Rectangle())
    .onTapGesture { studio.focusFilter(on: nil) }
    .accessibilityAddTraits(focused ? .isSelected : [])
  }

  // MARK: - Preview

  private var preview: some View {
    let index = studio.filterSteps.firstIndex { $0.id == studio.filterFocus }
    let title = index.map { "After #\(studio.filterSteps[$0].number)" } ?? "Result"
    return VStack(alignment: .leading, spacing: Theme.Space.m) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
        Eyebrow(text: studio.filterShowsRemoved ? "\(title) · removed" : title)
        Text(Format.images(studio.filterPreview.count)).font(.swissCaption.monospacedDigit())
          .foregroundStyle(Theme.mutedForeground)
        Spacer()
        Toggle(
          index == nil ? "Show what the chain removed" : "Show what this step removed",
          isOn: Binding(
            get: { studio.filterShowsRemoved },
            set: {
              studio.filterShowsRemoved = $0
              studio.updateFilterPreview()
            })
        )
        .toggleStyle(.checkbox).font(.callout)
      }
      Hairline()
      if let traced = studio.filterTraced { TracePanel(path: traced) }
      if let problem = studio.filterProblem {
        note("The chain could not run", problem)
      } else if studio.filterRun == nil {
        note("Filtering…", "Comparing your steps with every image. This takes a moment the first time.")
      } else if studio.filterPreview.isEmpty {
        note(
          "No images here",
          studio.filterShowsRemoved
            ? "Nothing was removed at this point." : "Try a looser strictness, or different words.")
      } else {
        let photos = studio.filterPreview
        if studio.filterTraced == nil {
          Text("Click a photo to trace its way through the chain.")
            .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
        }
        PhotoGrid(photos: photos, thumbnailSize: min(studio.thumbnailSize, 160)) { photo in
          studio.traceFilter(photo)
        }.equatable()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func note(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      Text(title).font(.swissTitle)
      Text(text).font(.swissBody).foregroundStyle(Theme.mutedForeground)
        .frame(maxWidth: 420, alignment: .leading)
    }.padding(.top, Theme.Space.m)
  }

  private func message(_ title: String, _ text: String, offersIndex: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      Text(title).font(.swissHeading)
      Text(text).font(.swissBody).foregroundStyle(Theme.mutedForeground)
        .frame(maxWidth: 440, alignment: .leading)
      if offersIndex {
        Button("Index Now") { studio.indexFolder() }.buttonStyle(.swissPrimary)
          .disabled(studio.activity != nil).padding(.top, Theme.Space.s)
      }
    }
    .padding(.top, Theme.Space.l)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// The line joining two nodes, pointing down the chain.
private struct Connector: View {
  var body: some View {
    VStack(spacing: 0) {
      Rectangle().fill(Theme.mutedForeground).frame(width: Theme.hairline, height: Theme.Space.s + 2)
      Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        .foregroundStyle(Theme.mutedForeground)
    }
    .padding(.leading, Theme.Space.l)
    .padding(.vertical, 2)
    .accessibilityHidden(true)
  }
}

/// One keep/remove step: what it does, its words, how strict, and what it changed.
private struct StepNode: View {
  @EnvironmentObject private var studio: Studio
  let step: FilterStep
  let index: Int
  let isLast: Bool
  @State private var text: String

  init(step: FilterStep, index: Int, isLast: Bool) {
    self.step = step
    self.index = index
    self.isLast = isLast
    _text = State(initialValue: step.text)
  }

  var body: some View {
    let focused = studio.filterFocus == step.id
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      HStack(spacing: Theme.Space.s) {
        Tag(text: "#\(step.number)", filled: focused)
          .help("This step's number. It stays the same when steps move, so traces keep pointing here.")
        SegmentedChoice(
          options: FilterStep.Action.allCases,
          selection: Binding(
            get: { step.action }, set: { action in studio.updateStep(step.id) { $0.action = action } }),
          title: \.label, label: "Keep or remove")
        Spacer()
        IconButton(symbol: "arrow.up", label: "Move step up") { studio.moveStep(step.id, by: -1) }
          .disabled(index == 0)
        IconButton(symbol: "arrow.down", label: "Move step down") { studio.moveStep(step.id, by: 1) }
          .disabled(isLast)
        IconButton(symbol: "xmark", label: "Delete step") { studio.removeStep(step.id) }
      }
      // What happened to the traced photo here, on its own line so it never squeezes.
      if let verdict = studio.filterTrace[step.id] {
        TraceMark(verdict: verdict, action: step.action)
      } else if studio.filterTraced != nil {
        TraceMark(text: "Not reached", passed: nil)
      }
      TextField(
        step.action == .keep ? "Images to keep — e.g. portrait photos" : "Images to remove — e.g. blurry photos",
        text: $text
      )
      .textFieldStyle(.plain).font(.body)
      .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
      .background(Theme.background)
      .overlay(Rectangle().strokeBorder(Theme.mutedForeground, lineWidth: Theme.hairline))
      .onChange(of: text) { studio.updateStep(step.id) { $0.text = text } }
      .accessibilityLabel("Step #\(step.number) description")
      HStack(spacing: Theme.Space.s) {
        Menu {
          Picker(
            "Strictness",
            selection: Binding(
              get: { step.strictness },
              set: { value in studio.updateStep(step.id) { $0.strictness = value } })
          ) {
            ForEach(FilterStep.Strictness.allCases) { Text($0.label).tag($0) }
          }.pickerStyle(.inline).labelsHidden()
        } label: {
          Text("Strictness: \(step.strictness.label)").font(.callout)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Loose catches more images; Strict only takes clear matches.")
        Spacer()
        Text(summary).font(.swissCaption.monospacedDigit())
          .foregroundStyle(step.isActive ? Theme.foreground : Theme.mutedForeground)
      }
      careful
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .panel(emphasis: focused ? Theme.ink : nil)
    .contentShape(Rectangle())
    .onTapGesture { studio.focusFilter(on: step.id) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Step #\(step.number), \(step.action.label)")
    .accessibilityAddTraits(focused ? .isSelected : [])
  }

  /// Which model answers this step: the album's search index matching the
  /// description (instant), or a decision model looking at each image
  /// (slower, more accurate). Then what is left for that model to do.
  @ViewBuilder private var careful: some View {
    let alias = studio.decisionAlias(for: step)
    let model = alias.flatMap { alias in studio.decisionModels.first { $0.alias == alias } }
    let unchecked = step.careful ? studio.uncheckedCount(at: index) : 0
    VStack(alignment: .leading, spacing: Theme.Space.xs) {
      Menu {
        Picker(
          "Model",
          selection: Binding(
            get: { step.model }, set: { value in studio.updateStep(step.id) { $0.model = value } })
        ) {
          Text("Match description · \(studio.indexStatus?.modelName ?? "search index") — instant")
            .tag(String?.none)
          Text("Look with the default model · \(studio.decisionModel?.name ?? "chosen in Settings")")
            .tag(String?.some(FilterStep.defaultModel))
          ForEach(DecisionCatalog.entries, id: \.alias) { entry in
            let installed = studio.decisionModels.first { $0.alias == entry.alias }?.installed ?? false
            Text("Look with \(entry.name) — slower, more accurate\(installed ? "" : " (download needed)")")
              .tag(String?.some(entry.alias))
          }
        }.pickerStyle(.inline).labelsHidden()
      } label: {
        Label(studio.modelName(for: step), systemImage: step.careful ? "eye" : "text.magnifyingglass")
          .font(.callout)
      }
      .menuStyle(.borderlessButton).fixedSize()
      .help("The model this step uses. Matching the description is instant; a model that looks at each image is much more accurate and takes about a third of a second per image, once.")
      if let alias, step.isActive {
        if model?.installed != true {
          HStack(spacing: Theme.Space.s) {
            Text("Needs \(DecisionCatalog.entry(alias)?.name ?? alias) (\(Format.bytes(DecisionCatalog.entry(alias)?.downloadSize ?? 0))).")
              .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
            Button("Download") { studio.downloadModel(alias) }
              .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
              .disabled(studio.activity != nil)
          }
        } else if unchecked > 0 {
          HStack(spacing: Theme.Space.s) {
            Text("\(Format.images(unchecked)) not looked at yet — matched by description for now.")
              .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Look Now") { studio.lookAtImages(for: step.id) }
              .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
              .disabled(studio.activity != nil || studio.isFiltering)
              .help("Takes about a third of a second per image. You can stop at any time; the answers so far are kept.")
          }
        } else if studio.filterCounts(at: index) != nil {
          Text("Every image here has been looked at.")
            .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
        }
      }
    }
  }

  private var summary: String {
    guard step.isActive else { return "Describe the images to \(step.action.label.lowercased())" }
    guard let counts = studio.filterCounts(at: index) else { return "…" }
    let left = counts.input - counts.dropped
    return "\(Format.count(counts.input)) → \(Format.count(left))  ·  \(Format.count(counts.dropped)) out"
  }
}

// MARK: - Trace

/// A small marker of what happened to the traced photo at one node: green
/// tick, red cross or grey dash, always with words, never colour alone.
private struct TraceMark: View {
  let text: String
  /// True passed, false removed here, nil not reached or skipped.
  let passed: Bool?

  init(text: String, passed: Bool?) {
    self.text = text
    self.passed = passed
  }

  init(verdict: FilterVerdict, action: FilterStep.Action) {
    if case .inactive = verdict.evidence {
      self.init(text: "Skipped", passed: nil)
    } else if verdict.kept {
      self.init(text: action == .keep ? "Kept" : "Passed", passed: true)
    } else {
      self.init(text: "Removed here", passed: false)
    }
  }

  var body: some View {
    let symbol = passed.map { $0 ? "checkmark.circle.fill" : "xmark.circle.fill" } ?? "minus.circle"
    let colour: Color = passed.map { $0 ? .green : Theme.destructive } ?? Theme.mutedForeground
    Label(text, systemImage: symbol)
      .font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
      .foregroundStyle(colour)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(colour.opacity(0.12), in: Capsule())
      .accessibilityLabel("Traced photo: \(text)")
  }
}

/// One photo's way through the chain, step by step: what each node decided
/// and why, ending where it left or in the result. Click a row to show that node.
private struct TracePanel: View {
  @EnvironmentObject private var studio: Studio
  let path: String

  var body: some View {
    let photo = studio.library.first { $0.path == path }
    let trace = studio.filterRun?.trace(of: path) ?? []
    VStack(alignment: .leading, spacing: Theme.Space.s) {
      HStack(spacing: Theme.Space.s) {
        Thumbnail(path: path).frame(width: 36, height: 36)
          .clipShape(RoundedRectangle(cornerRadius: Theme.tagRadius))
        VStack(alignment: .leading, spacing: 1) {
          Eyebrow(text: "Trace")
          Text(URL(fileURLWithPath: path).lastPathComponent).font(.callout.weight(.semibold))
            .lineLimit(1).truncationMode(.middle)
        }
        Spacer()
        if let photo {
          Button("View Photo") { studio.showPreview(of: photo, in: studio.filterPreview.contains(photo) ? studio.filterPreview : [photo]) }
            .buttonStyle(SwissButtonStyle(kind: .secondary, compact: true))
        }
        IconButton(symbol: "xmark", label: "Close the trace") { studio.filterTraced = nil }
      }
      if trace.isEmpty, studio.filterRun != nil {
        Text(studio.filterSteps.isEmpty ? "The chain has no steps yet, so this photo is in the result." : "This photo is not in the chain any more.")
          .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
      }
      ForEach(trace, id: \.step) { verdict in
        if let step = studio.filterSteps.first(where: { $0.id == verdict.step }) { row(verdict, step) }
      }
      if let run = studio.filterRun, !trace.isEmpty {
        let inResult = run.result.contains(path)
        TraceMark(text: inResult ? "Reached the result" : "Did not reach the result", passed: inResult)
      }
    }
    .panel()
  }

  private func row(_ verdict: FilterVerdict, _ step: FilterStep) -> some View {
    Button {
      studio.focusFilter(on: step.id)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
        Text("#\(step.number)").font(.caption.weight(.semibold).monospacedDigit())
          .frame(width: 28, alignment: .leading)
        TraceMark(verdict: verdict, action: step.action)
        VStack(alignment: .leading, spacing: 1) {
          Text("\(step.action.label) “\(step.text.trimmingCharacters(in: .whitespaces))”")
            .font(.callout).lineLimit(1).truncationMode(.tail)
          Text(Self.reason(verdict, studio: studio))
            .font(.swissCaption).foregroundStyle(Theme.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Show #\(step.number) in the chain")
  }

  /// Why the step decided as it did, in words and the numbers it compared.
  static func reason(_ verdict: FilterVerdict, studio: Studio) -> String {
    func name(_ alias: String) -> String {
      studio.decisionModels.first { $0.alias == alias }?.name ?? DecisionCatalog.entry(alias)?.name ?? alias
    }
    func lead(_ value: Float) -> String { String(format: "%+.3f", value) }
    let fits = verdict.matched ? "Fits the description" : "Does not fit the description"
    switch verdict.evidence {
    case .inactive:
      return "The step has no words yet, so everything passes."
    case .description(let value, let needed):
      return "\(fits): \(lead(value)) over a plain photo, \(lead(needed)) needed (\(studio.indexStatus?.modelName ?? "search index"))."
    case .model(let alias, let yes, let needed):
      return "\(fits): \(name(alias)) is \(Int((yes * 100).rounded()))% sure, \(Int((needed * 100).rounded()))% needed."
    case .notLookedAt(let alias, let unreadable, let value, let needed):
      let why = unreadable ? "\(name(alias)) cannot read this file" : "\(name(alias)) has not looked yet"
      return "\(why); by description for now: \(lead(value)) over a plain photo, \(lead(needed)) needed."
    }
  }
}
