#if canImport(CoreAI)
  import CoreAI
#endif
import Foundation
import MLX
import Metal
import XCTest

@testable import CurioKit

/// The decision model on Core AI beside MLX: what the Core AI export is traced
/// from, and a speed and memory comparison of the two runtimes. Opt in:
///
///   CURIO_D1_DUMP=<dir>    write the inputs the app builds for one picture and
///                          question, and MLX's scores for them (export.py reads these)
///   CURIO_D1_BENCH=<dir>   time both runtimes over the pictures in <dir>; one
///                          runtime per process (CURIO_D1_BACKEND=mlx|coreai), so
///                          each process's peak memory belongs to one runtime
///   CURIO_D1_AIMODEL=<file.aimodel>  the exported model, for Core AI
final class D1CoreAITests: XCTestCase {
  static let question = "a photo of mountains"
  private var environment: [String: String] { ProcessInfo.processInfo.environment }

  /// The question as filter steps ask it, so the benchmark measures what the app runs.
  static var asked: String { FilterStep(action: .keep, text: question).question }

  func testDumpInputsForTheCoreAIExport() async throws {
    let out = try required("CURIO_D1_DUMP", "set CURIO_D1_DUMP to export inputs")
    let alias = environment["CURIO_D1_ALIAS"] ?? D1Fixtures.compactAlias
    let model = try await D1DecisionModel.load(
      alias: alias, directory: D1Fixtures.directory(of: alias), shaders: D1Fixtures.shaders)
    let image = try required("CURIO_D1_IMAGE", "set CURIO_D1_IMAGE to the picture to trace with")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let dump = try await model.inputsForExport(image: image, question: Self.asked)
    try JSONEncoder().encode(dump).write(to: out.appendingPathComponent("inputs.json"))
    print("D1 dump: grid \(dump.rows)x\(dump.columns), length \(dump.ids.count), MLX scores \(dump.scores)")
  }
}

extension D1CoreAITests {
  /// One runtime over every picture in CURIO_D1_BENCH, timed, with this
  /// process's memory; appends one JSON line to CURIO_D1_RESULT.
  func testBenchmarkOneRuntime() async throws {
    let folder = try required("CURIO_D1_BENCH", "set CURIO_D1_BENCH to a folder of square pictures")
    let backend = environment["CURIO_D1_BACKEND"] ?? "mlx"
    let alias = environment["CURIO_D1_ALIAS"] ?? D1Fixtures.compactAlias
    let checkpoint = D1Fixtures.directory(of: alias)
    let images = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    try XCTSkipIf(images.isEmpty, "no pictures in \(folder.path)")

    let before = Memory.footprint
    var started = Date()
    let model: any DecisionModel
    switch backend {
    case "coreai":
      #if canImport(CoreAI)
        guard #available(macOS 27.0, *) else { throw XCTSkip("Core AI needs macOS 27") }
        let asset = try required("CURIO_D1_AIMODEL", "set CURIO_D1_AIMODEL to the exported .aimodel")
        if environment["CURIO_D1_COLD"] == "1" { try AIModelCache.default.deleteEntries(for: asset) }
        model = try await CoreAIDecisionModel.load(alias: alias, asset: asset, checkpoint: checkpoint)
      #else
        throw XCTSkip("Core AI needs the macOS 27 SDK")
      #endif
    default:
      model = try await D1DecisionModel.load(alias: alias, directory: checkpoint, shaders: D1Fixtures.shaders)
    }
    let load = Date().timeIntervalSince(started)
    let loaded = Memory.footprint

    started = Date()
    let first = try await model.decide(image: images[0], questions: [Self.asked])[0]
    let firstSeconds = Date().timeIntervalSince(started)
    var seconds: [Double] = []
    var answers: [String: Double] = [images[0].lastPathComponent: first]
    for image in images {
      started = Date()
      answers[image.lastPathComponent] = try await model.decide(image: image, questions: [Self.asked])[0]
      seconds.append(Date().timeIntervalSince(started))
    }
    let sorted = seconds.sorted()
    var gpu: [String: Double] = [:]
    if backend == "mlx" {
      gpu = ["activeMB": Double(MLX.Memory.activeMemory) / 1e6, "peakMB": Double(MLX.Memory.peakMemory) / 1e6,
             "cacheMB": Double(MLX.Memory.cacheMemory) / 1e6]
    } else if let device = MTLCreateSystemDefaultDevice() {
      gpu = ["metalAllocatedMB": Double(device.currentAllocatedSize) / 1e6]
    }
    let result: [String: Any] = [
      "backend": backend, "alias": alias, "images": images.count, "cold": environment["CURIO_D1_COLD"] == "1",
      "loadSeconds": load, "firstSeconds": firstSeconds,
      "meanSeconds": seconds.reduce(0, +) / Double(seconds.count), "medianSeconds": sorted[sorted.count / 2],
      "minSeconds": sorted.first!, "maxSeconds": sorted.last!,
      "footprintBeforeMB": before / 1e6, "footprintLoadedMB": loaded / 1e6,
      "footprintAfterMB": Memory.footprint / 1e6, "footprintPeakMB": Memory.peakFootprint / 1e6,
      "gpu": gpu, "answers": answers,
    ]
    let line = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    if let out = environment["CURIO_D1_RESULT"] {
      let url = URL(fileURLWithPath: out)
      if !FileManager.default.fileExists(atPath: out) { FileManager.default.createFile(atPath: out, contents: nil) }
      let handle = try FileHandle(forWritingTo: url)
      try handle.seekToEnd()
      try handle.write(contentsOf: line + Data("\n".utf8))
      try handle.close()
    }
    print("D1 bench \(backend): load \(String(format: "%.2f", load)) s, first \(String(format: "%.3f", firstSeconds)) s, median \(String(format: "%.3f", sorted[sorted.count / 2])) s/image, peak \(Int(Memory.peakFootprint / 1e6)) MB")
  }

  /// The path in environment variable `name`, or a skip saying how to set it.
  func required(_ name: String, _ message: String) throws -> URL {
    let value = ProcessInfo.processInfo.environment[name]
    try XCTSkipUnless(value != nil, message)
    return URL(fileURLWithPath: value!)
  }
}

/// Everything one pass reads, as the app builds it, plus MLX's answer to it.
struct D1ExportInputs: Codable {
  let rows: Int
  let columns: Int
  let patchValues: Int
  let patches: [Float]
  let ids: [Int]
  let stateLength: Int
  let groups: [Int]
  let slots: [Int]
  let imageStart: Int
  let imageTokens: Int
  let yesTokens: [Int]
  let noTokens: [Int]
  let slidingWindow: Int
  let fullMask: [Bool]
  let slidingMask: [Bool]
  let scores: [[Float]]
  let temperature: Double
}

extension D1DecisionModel {
  func inputsForExport(image: URL, question: String) throws -> D1ExportInputs {
    let picture = try layout.picture(at: image)
    let features = try network.features(of: picture)
    let row = try prompt.row(imageTokens: features.dim(0), questions: [question])
    let hidden = try network.hidden(for: row, features: features, imageToken: prompt.imageTokenID)
    let tokens = prompt.yesTokens + prompt.noTokens
    let scores = try network.scores(hidden: hidden, slots: row.slots, tokens: tokens)
    let window = network.config.text.slidingWindow
    let length = row.ids.count
    var sliding = [Bool](repeating: false, count: length * length)
    for reader in 0..<length {
      for read in max(0, reader - window + 1)...reader { sliding[reader * length + read] = true }
    }
    return D1ExportInputs(
      rows: picture.rows, columns: picture.columns, patchValues: picture.patches.count / picture.patchCount,
      patches: picture.patches, ids: row.ids, stateLength: row.stateLength, groups: row.groups,
      slots: row.slots, imageStart: row.ids.firstIndex(of: prompt.imageTokenID) ?? 0,
      imageTokens: features.dim(0), yesTokens: prompt.yesTokens, noTokens: prompt.noTokens,
      slidingWindow: window, fullMask: D1Masks.fullValues(row), slidingMask: sliding, scores: scores,
      temperature: calibration.yesNoTemperature)
  }
}

/// This process's memory as macOS accounts it: physical footprint, which on
/// Apple silicon includes what the GPU holds for it (memory is unified).
enum Memory {
  static var footprint: Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) : 0
  }

  /// The highest footprint this process has had.
  static var peakFootprint: Double {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    return result == 0 ? Double(usage.ri_lifetime_max_phys_footprint) : 0
  }
}
