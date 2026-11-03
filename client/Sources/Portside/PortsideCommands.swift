import SwiftUI

struct PortsideCommands: Commands {
  @ObservedObject var model: AppModel
  @ObservedObject var preferences: AppPreferences

  var body: some Commands {
    MainWindowCommands()
    CommandGroup(after: .appSettings) {
      Toggle("Run in Menu Bar", isOn: $preferences.runInMenuBar)
    }
    CommandGroup(replacing: .newItem) {
      Button("New Forward…") {
        if let id = model.selectedServerID {
          model.forwardEditor = ForwardEditorContext(serverID: id)
        } else {
          model.serverEditor = ServerEditorContext()
        }
      }.keyboardShortcut("n")
      Button("Add Server…") { model.serverEditor = ServerEditorContext() }
        .keyboardShortcut("n", modifiers: [.command, .shift])
    }
    CommandMenu("Transfer") {
      Button("Paste Image or Files") { model.pasteFiles() }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(model.selectedServerID == nil)
    }
    CommandMenu("Server") {
      HostSettingsButton(preferences: preferences)
    }
  }
}
