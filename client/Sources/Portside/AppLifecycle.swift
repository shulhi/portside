import AppKit
import SwiftUI

enum PortsideWindow {
  static let main = "portside-main"
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
  let model = AppModel()
  var showMainWindow: (() -> Void)?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(
      UserDefaults.standard.bool(forKey: AppPreferences.menuBarKey) ? .accessory : .regular)
    Task { await model.restore() }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    guard let showMainWindow else { return true }
    showMainWindow()
    sender.activate()
    return false
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.shutdown()
  }
}

struct MainWindowView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var preferences: AppPreferences
  let lifecycle: AppLifecycle
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    ContentView(model: model, preferences: preferences)
      .frame(minWidth: 780, minHeight: 440)
      .onAppear {
        // Retain the scene-opening action while its last window is closed.
        lifecycle.showMainWindow = { openWindow(id: PortsideWindow.main) }
      }
      .task { await model.restore() }
  }
}

struct MainWindowCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .windowArrangement) {
      Button("Show Portside") { openWindow(id: PortsideWindow.main) }
        .keyboardShortcut("0", modifiers: .command)
    }
  }
}
