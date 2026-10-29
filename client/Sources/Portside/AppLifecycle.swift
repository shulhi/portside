import AppKit
import SwiftUI

enum PortsideWindow {
  static let main = "portside-main"
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
  var showMainWindow: (() -> Void)?
  var shutdown: (() -> Void)?

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
    shutdown?()
  }
}

struct MainWindowView: View {
  @ObservedObject var model: AppModel
  let lifecycle: AppLifecycle
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    ContentView(model: model)
      .frame(minWidth: 760, minHeight: 440)
      .onAppear {
        // Retain the scene-opening action while its last window is closed.
        lifecycle.showMainWindow = { openWindow(id: PortsideWindow.main) }
        lifecycle.shutdown = { model.shutdown() }
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
