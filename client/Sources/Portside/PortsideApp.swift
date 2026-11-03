import AppKit
import SwiftUI

@main
struct PortsideApp: App {
  @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
  @StateObject private var preferences = AppPreferences()
  private var model: AppModel { lifecycle.model }

  var body: some Scene {
    Window("Portside", id: PortsideWindow.main) {
      MainWindowView(model: model, preferences: preferences, lifecycle: lifecycle)
    }
    .defaultSize(width: 860, height: 520)
    .windowToolbarStyle(.unified)
    .commands {
      PortsideCommands(model: model, preferences: preferences)
    }
    Settings {
      AppSettingsView(preferences: preferences, host: model.hostedServer)
    }
    MenuBarExtra(
      "Portside", systemImage: "arrow.left.arrow.right", isInserted: $preferences.runInMenuBar
    ) {
      MenuBarContent(model: model, preferences: preferences)
    }.menuBarExtraStyle(.menu)
  }
}
