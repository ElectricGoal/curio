import XCTest

@testable import LumaKit

final class InstallationTests: XCTestCase {
  private let support = URL(fileURLWithPath: "/Users/me/Library/Application Support")

  private func resolve(
    environment: [String: String] = [:], linked: String? = nil,
    bundle: String = "/Applications/ImageSearch.app", existing: Set<String> = []
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
      installation.dataRoot.path, "/Users/me/Library/Application Support/ImageSearch")
  }

  func testDataFolderCanBeRedirected() {
    let installation = resolve(environment: ["IMGSEARCH_DATA_ROOT": "/Volumes/Big/luma"])
    XCTAssertEqual(installation, Installation(kind: .installed, dataRoot: URL(fileURLWithPath: "/Volumes/Big/luma")))
  }

  func testDevelopmentBuildUsesTheCheckoutItWasLinkedTo() {
    let installation = resolve(linked: "/Users/dev/repo")
    XCTAssertEqual(installation.kind, .checkout)
    XCTAssertEqual(installation.dataRoot.path, "/Users/dev/repo")
  }

  func testExplicitProjectRootOverridesEverything() {
    let installation = resolve(
      environment: ["IMGSEARCH_PROJECT_ROOT": "/tmp/override", "IMGSEARCH_DATA_ROOT": "/elsewhere"],
      linked: "/Users/dev/repo")
    XCTAssertEqual(installation, .checkout(URL(fileURLWithPath: "/tmp/override")))
  }

  func testUnlinkedBuildFindsTheSourceTreeAboveIt() {
    let installation = resolve(
      bundle: "/Users/dev/repo/macos/.build/debug/ImageSearch",
      existing: ["/Users/dev/repo/macos/Package.swift"])
    XCTAssertEqual(installation, .checkout(URL(fileURLWithPath: "/Users/dev/repo")))
  }
}
