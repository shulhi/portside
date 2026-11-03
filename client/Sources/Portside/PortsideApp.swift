import AppKit
import SwiftUI

@main
struct PortsideApp: App {
  @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
  @StateObject private var model = AppModel()

  var body: some Scene {
    Window("Portside", id: PortsideWindow.main) {
      MainWindowView(model: model, lifecycle: lifecycle)
    }
    .defaultSize(width: 920, height: 560)
    .windowStyle(.hiddenTitleBar)
    .commands {
      MainWindowCommands()
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
      CommandMenu("Transfer") {
        Button("Paste Image or Files") { model.pasteFiles() }
          .keyboardShortcut("v", modifiers: [.command, .shift])
          .disabled(model.selectedServerID == nil)
      }
      CommandMenu("Server") {
        SettingsLink { Text("Host This Mac…") }
      }
    }
    Settings {
      HostingSettingsView(host: model.hostedServer)
    }
  }
}
