import Foundation
import Testing

@testable import Portside

@MainActor
struct AppPreferencesTests {
  @Test func repeatedSceneBindingValuesDoNotPublishOrReapplyPolicy() async throws {
    let name = "app.portside.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var policies: [Bool] = []
    var emissions = 0
    let preferences = AppPreferences(defaults: defaults) { policies.append($0) }
    let observation = preferences.objectWillChange.sink { emissions += 1 }
    defer { observation.cancel() }

    preferences.runInMenuBar = false
    preferences.settingsTab = .general
    #expect(emissions == 0)
    #expect(preferences.activationUpdate == nil)

    preferences.runInMenuBar = true
    await preferences.activationUpdate?.value
    for _ in 0..<10 { preferences.runInMenuBar = true }
    #expect(emissions == 1)
    #expect(policies == [true])
    preferences.settingsTab = .hosting
    for _ in 0..<10 { preferences.settingsTab = .hosting }
    #expect(emissions == 2)
  }

  @Test func menuBarModePersistsAndRestoresDockAccess() async throws {
    let name = "app.portside.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var policies: [Bool] = []
    let preferences = AppPreferences(defaults: defaults) { policies.append($0) }
    #expect(!preferences.runInMenuBar)
    preferences.runInMenuBar = true
    await preferences.activationUpdate?.value
    #expect(policies == [true])
    let restored = AppPreferences(defaults: defaults, applyPolicy: { _ in })
    #expect(restored.runInMenuBar)

    // This is also the binding change delivered when the menu-bar item is removed.
    preferences.runInMenuBar = false
    await preferences.activationUpdate?.value
    #expect(policies == [true, false])
    #expect(!defaults.bool(forKey: AppPreferences.menuBarKey))
  }

  @Test func rapidModeChangesCannotLeaveTheDockHidden() async throws {
    let name = "app.portside.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var policies: [Bool] = []
    let preferences = AppPreferences(defaults: defaults) { policies.append($0) }
    preferences.runInMenuBar = true
    preferences.runInMenuBar = false
    await preferences.activationUpdate?.value
    #expect(policies == [false])
  }
}
