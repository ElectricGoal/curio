import Accelerate
import Foundation

/// The linear algebra behind search: dot products over unit vectors.
public enum VectorMath {
  public static func normalized(_ vector: [Float]) -> [Float] {
    var length: Float = 0
    vDSP_svesq(vector, 1, &length, vDSP_Length(vector.count))
    length = length.squareRoot()
    guard length > 0, length.isFinite else { return vector }
    return vDSP.divide(vector, length)
  }

  public static func dot(_ first: [Float], _ second: [Float]) -> Float {
    vDSP.dot(first, second)
  }

  /// Similarity of `query` to every row of `matrix` (`rows × dimension`, row-major).
  public static func scores(matrix: [Float], rows: Int, dimension: Int, query: [Float]) -> [Float] {
    guard rows > 0, query.count == dimension, matrix.count == rows * dimension else { return [] }
    var result = [Float](repeating: 0, count: rows)
    vDSP_mmul(
      matrix, 1, query, 1, &result, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
    return result
  }

  /// `matrix` (`rows × dimension`) with rows and columns swapped.
  public static func transposed(_ matrix: [Float], rows: Int, dimension: Int) -> [Float] {
    var result = [Float](repeating: 0, count: matrix.count)
    vDSP_mtrans(matrix, 1, &result, 1, vDSP_Length(dimension), vDSP_Length(rows))
    return result
  }

  /// Similarities between a block of rows and every row: `blockCount × rows`,
  /// row-major. `transposed` is `transposed(matrix, …)`, computed once by the
  /// caller rather than once per block.
  public static func scores(
    matrix: [Float], transposed: [Float], rows: Int, dimension: Int, blockStart: Int,
    blockCount: Int
  ) -> [Float] {
    var result = [Float](repeating: 0, count: blockCount * rows)
    matrix.withUnsafeBufferPointer { all in
      vDSP_mmul(
        all.baseAddress! + blockStart * dimension, 1, transposed, 1, &result, 1,
        vDSP_Length(blockCount), vDSP_Length(rows), vDSP_Length(dimension))
    }
    return result
  }

  /// Indices of the `limit` highest scores, best first.
  public static func top(_ scores: [Float], limit: Int) -> [Int] {
    Array(scores.indices.sorted { scores[$0] > scores[$1] }.prefix(max(0, limit)))
  }
}
