import Foundation

/// A description the model compares every image with, and what it means to the app.
public struct CurationLabel: Hashable, Sendable, Identifiable {
  public enum Kind: String, Sendable { case tag, junk, album }

  /// Shown to the user.
  public let name: String
  /// What the model reads.
  public let prompt: String
  public let kind: Kind
  /// One line on what the label catches, for the Clean Up page.
  public let detail: String

  public var id: String { "\(kind.rawValue):\(name)" }

  public init(name: String, prompt: String, kind: Kind, detail: String = "") {
    self.name = name
    self.prompt = prompt
    self.kind = kind
    self.detail = detail
  }
}

/// The labels Curio knows without being told.
public enum Labels {
  public static let tags: [CurationLabel] = [
    ("Beach", "a photo of a beach"), ("Mountains", "a photo of mountains"),
    ("Forest", "a photo of a forest"), ("Snow", "a photo of snow"),
    ("Sunset", "a photo of a sunset"), ("Night", "a photo taken at night"),
    ("Sky", "a photo of the sky and clouds"), ("Water", "a photo of a lake, river or sea"),
    ("City", "a photo of a city street"), ("Architecture", "a photo of a building"),
    ("Indoors", "a photo of a room indoors"), ("Food", "a photo of food"),
    ("Drinks", "a photo of a drink"), ("Dogs", "a photo of a dog"), ("Cats", "a photo of a cat"),
    ("Birds", "a photo of a bird"), ("Wildlife", "a photo of a wild animal"),
    ("People", "a photo of a group of people"), ("Portraits", "a portrait photo of a person"),
    ("Babies", "a photo of a baby"), ("Cars", "a photo of a car"),
    ("Flowers", "a photo of flowers"), ("Plants", "a photo of green plants"),
    ("Art", "a painting or artwork"), ("Sports", "a photo of people playing sport"),
    ("Concerts", "a photo of a concert"), ("Celebrations", "a photo of a party or celebration"),
    ("Graphics", "a graphic design, icon or illustration"),
    // Without it, wallpapers and gradients are taken for screenshots.
    ("Abstract", "an abstract colorful wallpaper"),
  ].map { CurationLabel(name: $0.0, prompt: $0.1, kind: .tag) }

  public static let junk: [CurationLabel] = [
    ("Screenshots", "a screenshot of a computer or phone screen", "Captures of a phone or computer screen."),
    ("Memes", "a meme with caption text", "Pictures with joke captions, usually saved from the web."),
    ("Documents", "a photo of a paper document", "Photos of pages, forms and printed text."),
    ("Receipts", "a photo of a receipt", "Receipts and bills photographed for later."),
    ("Whiteboards", "a photo of a whiteboard", "Notes and diagrams on a board."),
    ("Blurry shots", "a blurry, out of focus photo", "Out of focus or shaken photos."),
    ("Dark or blank", "a completely black or blank image", "Almost nothing visible: lens covered, lights off."),
    ("Accidental shots", "an accidental photo of the floor or a pocket", "Floors, pockets and fingers."),
  ].map { CurationLabel(name: $0.0, prompt: $0.1, kind: .junk, detail: $0.2) }

  /// A smart album: the user's own words, phrased the way CLIP matches best
  /// ("flowers" alone scores well below "a photo of flowers").
  public static func album(_ name: String) -> CurationLabel {
    let lowered = name.lowercased()
    let phrased = ["a ", "an ", "the ", "photo"].contains(where: lowered.hasPrefix) ? name : "a photo of \(name)"
    return CurationLabel(name: name, prompt: phrased, kind: .album)
  }

  /// Compared to pick the best of a group of similar shots.
  public static let goodShot = "a sharp, well-lit, well-composed photo"
  public static let badShot = "a blurry, dark, badly composed photo"
}

/// Which images carry which labels, worked out from `PromptScores`.
public struct Curation: Equatable, Sendable {
  public struct Member: Equatable, Sendable {
    public let path: String
    public let score: Float
  }

  // shortcut: fixed cut-offs chosen by reasoning, not measured; tune them on real libraries.
  /// CLIP's own logit scale: turns cosines into confident probabilities.
  static let logitScale: Float = 100
  /// A tag needs this much of the probability, among an image's three best labels.
  static let tagMinimum: Float = 0.25
  static let tagsPerImage = 3
  /// Clutter must be the image's single best label, and a clear one.
  static let junkMinimum: Float = 0.35
  /// An album takes images it matches nearly as well as their best built-in label.
  static let albumMargin: Float = 0.01

  /// Members of each label (by `id`), best match first.
  public let members: [String: [Member]]
  /// Tags of each image, best first.
  public let tagsByPath: [String: [CurationLabel]]
  /// How many images were sorted; tells whether the index has changed since.
  public let imageCount: Int

  public init(members: [String: [Member]], tagsByPath: [String: [CurationLabel]], imageCount: Int) {
    self.members = members
    self.tagsByPath = tagsByPath
    self.imageCount = imageCount
  }

  /// `labels` are in the order their prompts were scored.
  public init(scores: PromptScores, labels: [CurationLabel]) {
    precondition(labels.count == scores.prompts, "one label per scored prompt")
    let builtIn = labels.indices.filter { labels[$0].kind != .album }
    let albums = labels.indices.filter { labels[$0].kind == .album }
    var members: [String: [Member]] = [:]
    var tagsByPath: [String: [CurationLabel]] = [:]
    let width = scores.prompts
    for (row, path) in scores.paths.enumerated() {
      let cosines = scores.scores[(row * width)..<((row + 1) * width)].map { $0 }
      guard let topCosine = builtIn.map({ cosines[$0] }).max() else { continue }
      // Softmax over the built-in labels, so they compete for each image.
      let exps = builtIn.map { exp(Self.logitScale * (cosines[$0] - topCosine)) }
      let total = exps.reduce(0, +)
      let ranked = zip(builtIn, exps.map { $0 / total }).sorted { $0.1 > $1.1 }
      var tags: [CurationLabel] = []
      for (rank, (index, probability)) in ranked.prefix(Self.tagsPerImage).enumerated() {
        let label = labels[index]
        if label.kind == .tag, probability >= Self.tagMinimum {
          tags.append(label)
          members[label.id, default: []].append(Member(path: path, score: probability))
        } else if label.kind == .junk, rank == 0, probability >= Self.junkMinimum {
          members[label.id, default: []].append(Member(path: path, score: probability))
        }
      }
      if !tags.isEmpty { tagsByPath[path] = tags }
      for index in albums where cosines[index] >= topCosine - Self.albumMargin {
        members[labels[index].id, default: []].append(Member(path: path, score: cosines[index]))
      }
    }
    self.init(
      members: members.mapValues { $0.sorted { ($0.score, $1.path) > ($1.score, $0.path) } },
      tagsByPath: tagsByPath, imageCount: scores.paths.count)
  }

  public func paths(for label: CurationLabel) -> [String] { members[label.id]?.map(\.path) ?? [] }
  public func count(for label: CurationLabel) -> Int { members[label.id]?.count ?? 0 }
  public func tags(of path: String) -> [CurationLabel] { tagsByPath[path] ?? [] }

  /// Labels with at least one image, most images first.
  public func used(_ labels: [CurationLabel]) -> [(label: CurationLabel, count: Int)] {
    labels.map { ($0, count(for: $0)) }.filter { $0.1 > 0 }
      .sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }
  }

  /// A copy without files that are gone (moved to the Trash).
  public func removing(_ paths: Set<String>) -> Curation {
    Curation(
      members: members.mapValues { $0.filter { !paths.contains($0.path) } }.filter { !$0.value.isEmpty },
      tagsByPath: tagsByPath.filter { !paths.contains($0.key) }, imageCount: imageCount)
  }
}

/// Words that steer a search by example: "at night, -people".
public struct SearchRefinement: Equatable, Sendable {
  public let adding: [String]
  public let removing: [String]

  public init(adding: [String] = [], removing: [String] = []) {
    self.adding = adding
    self.removing = removing
  }

  /// Comma-separated terms. A term starting with "-", "no " or "without " is taken away.
  public init(parsing text: String) {
    var adding: [String] = []
    var removing: [String] = []
    for raw in text.split(separator: ",") {
      let term = raw.trimmingCharacters(in: .whitespaces)
      let lowered = term.lowercased()
      if let prefix = ["-", "−", "no ", "without "].first(where: lowered.hasPrefix) {
        let rest = term.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { removing.append(rest) }
      } else if !term.isEmpty {
        adding.append(term)
      }
    }
    self.init(adding: adding, removing: removing)
  }

  public var isEmpty: Bool { adding.isEmpty && removing.isEmpty }

  /// "+ at night − people".
  public var summary: String {
    (adding.map { "+ \($0)" } + removing.map { "− \($0)" }).joined(separator: " ")
  }
}
