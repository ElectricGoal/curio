import AppKit
import CurioKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Entry point: the app, or its self-test when asked for on the command line.
@main enum Launcher {
  @MainActor static func main() async {
    guard CommandLine.arguments.contains(SelfTest.flag) else {
      CurioApp.main()
      return
    }
    exit(
      await SelfTest.run(
        installation: AppEnvironment.installation, bundledModels: AppEnvironment.bundledModels))
  }
}

/// How this copy of the app is set up, read once from its bundle and environment.
enum AppEnvironment {
  static let environment = ProcessInfo.processInfo.environment

  static func info(_ key: String) -> String? {
    Bundle.main.object(forInfoDictionaryKey: key) as? String
  }

  static var installation: Installation {
    Installation.resolve(
      environment: environment, linkedProjectRoot: info("CurioProjectRoot"),
      bundle: Bundle.main.bundleURL,
      applicationSupport: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first ?? FileManager.default.homeDirectoryForCurrentUser,
      currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
  }

  /// Models shipped inside the app bundle.
  static var bundledModels: URL? { Bundle.main.resourceURL?.appendingPathComponent("models") }

  /// Where models are downloaded from: Curio's public Hugging Face repository.
  static let defaultModelsURL = "https://huggingface.co/ElectricGoal/curio-models/resolve/main"

  /// A host serving converted models. `CURIO_MODELS_URL` or the bundle can point
  /// elsewhere; an empty value turns downloads off.
  static var remoteModels: URL? {
    let address = environment["CURIO_MODELS_URL"] ?? info("CurioModelsURL") ?? defaultModelsURL
    return address.isEmpty ? nil : URL(string: address)
  }
}

struct CurioApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var studio = Studio()

  var body: some Scene {
    Window("Curio", id: "main") {
      StudioView().environmentObject(studio).frame(minWidth: 980, minHeight: 650)
        // Folders opened from Finder, the Dock icon or `open -a` arrive here.
        .onOpenURL { url in _ = studio.handleDrop([url]) }
        .onAppear { studio.start() }
    }
    // Without this, launching the app *with* a folder would not show the window.
    .handlesExternalEvents(matching: ["*"])
    .defaultSize(width: 1280, height: 820)

    // Models are an app-wide setting, so they live where macOS puts settings: ⌘,
    Settings {
      SettingsView().environmentObject(studio)
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Open Folder…") { studio.chooseFolder() }.keyboardShortcut("o")
        Menu("Open Recent") {
          ForEach(studio.recentFolders, id: \.self) { url in
            Button(url.lastPathComponent) { studio.open(url) }
          }
        }.disabled(studio.recentFolders.isEmpty)
        Divider()
        Button("Show Folder in Finder") { studio.revealFolder() }
          .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(studio.folder == nil)
      }
      CommandGroup(after: .textEditing) {
        Button("Find…") { studio.focusSearch() }.keyboardShortcut("f")
          .disabled(studio.folder == nil)
      }
      CommandMenu("Library") {
        Button("Show All Photos") {
          studio.page = .library
          studio.clearSearch()
        }.keyboardShortcut("0").disabled(studio.folder == nil)
        Button("Reload Folder") { studio.reloadLibrary() }.keyboardShortcut("r")
          .disabled(studio.folder == nil)
        Divider()
        Button(studio.hasIndex ? "Update Search Index" : "Index for Search") {
          studio.indexFolder()
        }.keyboardShortcut("u").disabled(studio.folder == nil || studio.activity != nil)
        Button("Find Duplicates") {
          studio.page = .duplicates
          studio.findDuplicates()
        }.keyboardShortcut("d", modifiers: [.command, .shift])
          .disabled(studio.folder == nil || studio.activity != nil)
      }
    }
  }
}
