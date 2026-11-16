import XCTest

@testable import CurioKit

final class InstallationTests: XCTestCase {
  private let support = URL(fileURLWithPath: "/Users/me/Library/Application Support")

  private func resolve(
    environment: [String: String] = [:], linked: String? = nil,
    bundle: String = "/Applications/Curio.app", existing: Set<String> = []
  ) -> Installation {
    Installation.resolve(
      environment: environment, linkedProjectRoot: linked, bundle: URL(fileURLWithPath: bundle),
      applicationSupport: support, currentDirectory: URL(fileURLWithPath: "/cwd"),
      fileExists: { existing.contains($0) })
  }

  func testInstalledAppKeepsItsDataInApplicationSupport() {
    let installation = resolve()
    XCTAssertEqual(installation.kind, .installed)
    XCTAssertEqual(
      installation.dataRoot.path, "/Users/me/Library/Application Support/Curio")
  }

  func testDataFolderCanBeRedirected() {
    let installation = resolve(environment: ["CURIO_DATA_ROOT": "/Volumes/Big/curio"])
    XCTAssertEqual(installation, Installation(kind: .installed, dataRoot: URL(fileURLWithPath: "/Volumes/Big/curio")))
  }

  func testDevelopmentBuildUsesTheCheckoutItWasLinkedTo() {
    let installation = resolve(linked: "/Users/dev/repo")
    XCTAssertEqual(installation.kind, .checkout)
    XCTAssertEqual(installation.dataRoot.path, "/Users/dev/repo")
  }

  func testExplicitProjectRootOverridesEverything() {
    let installation = resolve(
      environment: ["CURIO_PROJECT_ROOT": "/tmp/override", "CURIO_DATA_ROOT": "/elsewhere"],
      linked: "/Users/dev/repo")
    XCTAssertEqual(installation, .checkout(URL(fileURLWithPath: "/tmp/override")))
  }

  func testUnlinkedBuildFindsTheSourceTreeAboveIt() {
    let installation = resolve(
      bundle: "/Users/dev/repo/macos/.build/debug/Curio",
      existing: ["/Users/dev/repo/macos/Package.swift"])
    XCTAssertEqual(installation, .checkout(URL(fileURLWithPath: "/Users/dev/repo")))
  }
}
