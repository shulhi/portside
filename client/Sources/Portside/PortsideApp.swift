import AppKit
import SwiftUI

@main
struct PortsideApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup("Portside") {
      ContentView(model: model)
        .frame(minWidth: 760, minHeight: 440)
        .task { await model.restore() }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in model.stopAll() }
    }
    .defaultSize(width: 920, height: 560)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Forward…") {
          if let id = model.selectedServerID {
            model.forwardEditor = ForwardEditorContext(serverID: id)
          } else {
            model.serverEditor = ServerEditorContext()
          }
        }.keyboardShortcut("n")
        Button("Add Server…") { model.serverEditor = ServerEditorContext() }.keyboardShortcut(
          "n", modifiers: [.command, .shift])
      }
    }
  }
}
