import AppKit
import Combine
import Foundation

enum SettingsTab: Hashable { case general, hosting }

@MainActor
final class AppPreferences: ObservableObject {
  static let menuBarKey = "runInMenuBar"
  @Published private var selectedSettingsTab = SettingsTab.general
  @Published private var menuBarMode: Bool
  var settingsTab: SettingsTab {
    get { selectedSettingsTab }
    set {
      guard selectedSettingsTab != newValue else { return }
      selectedSettingsTab = newValue
    }
  }
  var runInMenuBar: Bool {
    get { menuBarMode }
    set {
      // Scene bindings may write their current value during reconciliation.
      // Publishing that unchanged value makes MenuBarExtra rebuild itself forever.
      guard menuBarMode != newValue else { return }
      menuBarMode = newValue
      defaults.set(newValue, forKey: Self.menuBarKey)
      scheduleActivationUpdate()
    }
  }
  private let defaults: UserDefaults
  private let applyPolicy: (Bool) -> Void
  private(set) var activationUpdate: Task<Void, Never>?

  init(
    defaults: UserDefaults = .standard,
    applyPolicy: @escaping (Bool) -> Void = { menuBarOnly in
      NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
    }
  ) {
    self.defaults = defaults
    self.applyPolicy = applyPolicy
    menuBarMode = defaults.bool(forKey: Self.menuBarKey)
  }

  func scheduleActivationUpdate() {
    activationUpdate?.cancel()
    let enabled = runInMenuBar
    activationUpdate = Task { @MainActor [weak self] in
      // Let SwiftUI insert the menu-bar item before removing the Dock entry.
      await Task.yield()
      guard !Task.isCancelled, let self, self.runInMenuBar == enabled else { return }
      self.applyPolicy(enabled)
    }
  }
}
