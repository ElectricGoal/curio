import Foundation

/// Finds images that are copies of each other and chooses which to keep.
public enum DuplicateFinder {
  public struct Group: Equatable, Sendable {
    public let isExact: Bool
    public let similarity: Double
    public let keeper: String
    public let duplicates: [String]
  }

  /// Upper bound on similarity values held in memory at once (~256 MB).
  public static let blockCells = 64_000_000
  /// "copy of x", "x copy", "x copy 2", "x (1)": names Finder and browsers give duplicates.
  private static let copyName = try! NSRegularExpression(
    pattern: #"^copy of |\bcopy( \d+)?$|\(\d+\)$"#, options: [.caseInsensitive])

  /// Clusters of images at least `threshold` alike, with each cluster's best score.
  ///
  /// Compares a block of rows at a time so memory stays at block × n, not n × n.
  /// `onProgress(rowsCompared, rows)` is called after each block, and
  /// `isCancelled` is asked before each one; a yes throws `EngineError.cancelled`.
  public static func nearGroups(
    in snapshot: IndexSnapshot, threshold: Float, blockCells: Int = DuplicateFinder.blockCells,
    isCancelled: () -> Bool = { false }, onProgress: (Int, Int) -> Void = { _, _ in }
  ) throws -> [(paths: [String], similarity: Double)] {
    let rows = snapshot.paths.count
    guard rows > 1 else { return [] }
    let transposed = VectorMath.transposed(
      snapshot.matrix, rows: rows, dimension: snapshot.dimension)
    var clusters = UnionFind(count: rows)
    // Each image's closest match so far. A cluster's best score is the best of
    // its members', so matching pairs never need to be kept: a burst of a
    // thousand near-identical shots would otherwise mean half a million of them.
    var closest = [Float](repeating: 0, count: rows)
    let blockRows = max(1, min(1024, blockCells / rows))
    var start = 0
    while start < rows {
      guard !isCancelled() else { throw EngineError.cancelled }
      let count = min(blockRows, rows - start)
      let scores = VectorMath.scores(
        matrix: snapshot.matrix, transposed: transposed, rows: rows,
        dimension: snapshot.dimension, blockStart: start, blockCount: count)
      for row in 0..<count {
        // Only columns after the row itself: skips self-matches and mirrored pairs.
        for column in (start + row + 1)..<rows where scores[row * rows + column] >= threshold {
          let score = scores[row * rows + column]
          clusters.union(start + row, column)
          closest[start + row] = max(closest[start + row], score)
          closest[column] = max(closest[column], score)
        }
      }
      start += count
      onProgress(start, rows)
    }
    return clusters.groups().map { members in
      (
        paths: members.map { snapshot.paths[$0] }.sorted(),
        similarity: Double(members.map { closest[$0] }.max() ?? threshold)
      )
    }
  }

  /// Merges identical-file groups with look-alike clusters and picks a keeper for each.
  public static func groups(
    identical: [[String]], near: [(paths: [String], similarity: Double)],
    size: (String) -> Int64
  ) -> [Group] {
    var index: [String: Int] = [:]
    var names: [String] = []
    func id(_ path: String) -> Int {
      if let known = index[path] { return known }
      index[path] = names.count
      names.append(path)
      return names.count - 1
    }
    let identicalIDs = identical.map { $0.map(id) }
    let nearIDs = near.map { ($0.paths.map(id), $0.similarity) }
    var clusters = UnionFind(count: names.count)
    for group in identicalIDs { for member in group.dropFirst() { clusters.union(group[0], member) } }
    for (group, _) in nearIDs { for member in group.dropFirst() { clusters.union(group[0], member) } }
    var exactRoots: Set<Int> = []
    var similarity: [Int: Double] = [:]
    for group in identicalIDs where !group.isEmpty { exactRoots.insert(clusters.find(group[0])) }
    for (group, score) in nearIDs where !group.isEmpty {
      let root = clusters.find(group[0])
      similarity[root] = max(similarity[root] ?? 0, score)
    }
    return clusters.groups().map { members -> Group in
      let root = clusters.find(members[0])
      let paths = members.map { names[$0] }
      let keeper = keeper(among: paths, size: size)
      return Group(
        isExact: exactRoots.contains(root),
        similarity: exactRoots.contains(root) ? 1 : (similarity[root] ?? 1), keeper: keeper,
        duplicates: paths.filter { $0 != keeper }.sorted())
    }
    .sorted { ($0.similarity, $1.keeper) > ($1.similarity, $0.keeper) }
  }

  /// The largest file wins. Identical files always tie on size, so ties go to
  /// the one that does not look like a copy, then to the shorter path — the
  /// original survives rather than "photo copy 2.jpg".
  public static func keeper(among paths: [String], size: (String) -> Int64) -> String {
    paths.max { first, second in
      let a = (size(first), !looksLikeCopy(first), -first.count)
      let b = (size(second), !looksLikeCopy(second), -second.count)
      if a.0 != b.0 { return a.0 < b.0 }
      if a.1 != b.1 { return !a.1 && b.1 }
      if a.2 != b.2 { return a.2 < b.2 }
      return first > second
    } ?? ""
  }

  static func looksLikeCopy(_ path: String) -> Bool {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
      .trimmingCharacters(in: .whitespaces)
    return copyName.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) != nil
  }
}

/// Disjoint sets over the integers 0..<count.
struct UnionFind {
  private var parent: [Int]

  init(count: Int) {
    parent = Array(0..<count)
  }

  mutating func find(_ member: Int) -> Int {
    var root = member
    while parent[root] != root { root = parent[root] }
    var current = member
    while parent[current] != root { (current, parent[current]) = (parent[current], root) }
    return root
  }

  mutating func union(_ first: Int, _ second: Int) {
    let (a, b) = (find(first), find(second))
    if a != b { parent[max(a, b)] = min(a, b) }
  }

  /// Sets with more than one member, each in ascending order.
  mutating func groups() -> [[Int]] {
    var members: [Int: [Int]] = [:]
    for index in parent.indices { members[find(index), default: []].append(index) }
    return members.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
  }
}
