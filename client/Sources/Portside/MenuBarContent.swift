import AppKit
import SwiftUI

struct MenuBarContent: View {
  @ObservedObject var model: AppModel
  @ObservedObject var preferences: AppPreferences
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Text("\(model.activeCount) active · \(model.connectionCount) connections")
    Button("Open Portside", systemImage: "macwindow") { showWindow() }
      .keyboardShortcut("0")
    Divider()
    ForEach(model.servers) { server in
      let rules = model.configuration.forwards.filter { $0.serverID == server.id }
      if !rules.isEmpty {
        Section(server.name) {
          ForEach(rules) { rule in
            Button {
              if model.snapshot(rule).phase == .listening || model.starting.contains(rule.id) {
                model.stop(rule)
              } else {
                Task { await model.start(rule) }
              }
            } label: {
              Label {
                Text(verbatim: "\(rule.name) · \(rule.localPort) → \(rule.remotePort)")
              } icon: {
                Image(
                  systemName: model.snapshot(rule).phase == .listening
                    || model.starting.contains(rule.id) ? "stop.fill" : "play.fill")
              }
            }
          }
        }
      }
    }
    Button("New Forward…", systemImage: "plus") {
      showWindow()
      if let id = model.selectedServerID {
        model.forwardEditor = ForwardEditorContext(serverID: id)
      } else {
        model.serverEditor = ServerEditorContext()
      }
    }
    Button("Stop All Forwards") { model.stopAll() }.disabled(
      model.activeCount == 0 && model.starting.isEmpty)
    if model.errorMessage != nil {
      Button("Show Connection Error…", systemImage: "exclamationmark.triangle") { showWindow() }
    }
    Divider()
    Button("Settings…", systemImage: "gearshape") {
      preferences.settingsTab = .general
      openSettings()
      NSApp.activate()
    }.keyboardShortcut(",")
    Button("Show Dock Icon") {
      preferences.runInMenuBar = false
      showWindow()
    }
    Divider()
    Button("Quit Portside") {
      model.shutdown()
      NSApp.terminate(nil)
    }.keyboardShortcut("q")
  }

  private func showWindow() {
    openWindow(id: PortsideWindow.main)
    NSApp.activate()
  }
}
