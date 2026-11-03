import PortsideCore
import SwiftUI

struct AppSettingsView: View {
  @ObservedObject var preferences: AppPreferences
  @ObservedObject var host: HostedServer

  var body: some View {
    TabView(selection: $preferences.settingsTab) {
      GeneralSettingsView(preferences: preferences)
        .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
      HostingSettingsView(host: host)
        .tabItem { Label("Hosting", systemImage: "desktopcomputer") }.tag(SettingsTab.hosting)
    }.frame(width: 520).tint(Palette.accent)
  }
}

private struct GeneralSettingsView: View {
  @ObservedObject var preferences: AppPreferences

  var body: some View {
    Form {
      Section {
        Toggle("Run in menu bar", isOn: $preferences.runInMenuBar)
        Text(
          "Hide the Dock icon and control Portside from the menu bar. Closing the window keeps forwards, transfers, and hosting running."
        )
        .font(.callout).foregroundStyle(.secondary)
      }
      Section {
        Text(
          "Open the window from the Portside menu-bar icon. Choose Quit Portside there to stop the app, or turn this option off to restore the Dock icon."
        )
        .font(.callout).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped).frame(height: 250)
  }
}
