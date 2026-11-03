import AppKit
import Combine
import Foundation
import PortsideCore

enum ServerState {
  case unchecked, checking
  case ready(ServerInfo)
  case failed(String)
  var isReady: Bool { if case .ready = self { true } else { false } }
  var isChecking: Bool { if case .checking = self { true } else { false } }
}

struct ServerEditorContext: Identifiable {
  let id = UUID()
  var server: ServerProfile?
}

struct ForwardEditorContext: Identifiable {
  let id = UUID()
  var rule: ForwardRule?
  let serverID: UUID
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var configuration = ClientConfiguration()
  @Published var selectedServerID: UUID?
  @Published private(set) var serverStates: [UUID: ServerState] = [:]
  @Published private(set) var snapshots: [UUID: ForwardSnapshot] = [:]
  @Published private(set) var starting: Set<UUID> = []
  @Published var serverEditor: ServerEditorContext?
  @Published var forwardEditor: ForwardEditorContext?
  @Published var errorMessage: String?

  let engine = ForwardEngine()
  let transfers = FileTransferManager()
  let hostedServer = HostedServer()
  private let store = ConfigurationStore()
  private var observation: AnyCancellable?
  private var canSave = false
  private var restored = false
  private var startRequests: [UUID: UUID] = [:]

  init() {
    do {
      configuration = try store.load()
      selectedServerID = configuration.servers.first?.id
      canSave = true
    } catch {
      errorMessage =
        "Your saved configuration could not be loaded: \(error.localizedDescription) Existing settings have been preserved."
    }
    observation = engine.$snapshots.sink { [weak self] snapshots in self?.snapshots = snapshots }
  }

  var servers: [ServerProfile] { configuration.servers }
  var selectedServer: ServerProfile? { servers.first { $0.id == selectedServerID } }
  var visibleForwards: [ForwardRule] {
    configuration.forwards.filter { $0.serverID == selectedServerID }
  }
  var activeCount: Int { snapshots.values.filter { $0.phase == .listening }.count }
  var connectionCount: Int { snapshots.values.reduce(0) { $0 + $1.connections } }

  func snapshot(_ rule: ForwardRule) -> ForwardSnapshot { snapshots[rule.id] ?? ForwardSnapshot() }

  func saveServer(_ profile: ServerProfile) throws {
    try profile.validate()
    var next = configuration
    if let index = next.servers.firstIndex(where: { $0.id == profile.id }) {
      next.servers[index] = profile
    } else {
      next.servers.append(profile)
    }
    try persist(next)
    for rule in configuration.forwards where rule.serverID == profile.id { stop(rule) }
    transfers.cancel(serverID: profile.id)
    configuration = next
    selectedServerID = profile.id
    serverStates[profile.id] = .unchecked
  }

  func removeServer(_ server: ServerProfile) {
    var next = configuration
    next.servers.removeAll { $0.id == server.id }
    next.forwards.removeAll { $0.serverID == server.id }
    do {
      try persist(next)
      for rule in configuration.forwards where rule.serverID == server.id { stop(rule) }
      configuration = next
      serverStates.removeValue(forKey: server.id)
      transfers.cancel(serverID: server.id)
      selectedServerID = next.servers.first?.id

    } catch { errorMessage = error.localizedDescription }
  }

  func saveForward(_ rule: ForwardRule, startNow: Bool) throws {
    try rule.validate()
    guard servers.contains(where: { $0.id == rule.serverID }) else {
      throw PortsideError.invalid("Choose a saved server.")
    }
    guard
      !configuration.forwards.contains(where: { $0.id != rule.id && $0.localPort == rule.localPort }
      )
    else {
      throw PortsideError.invalid(
        "Another saved forward already uses local port \(rule.localPort). Choose a different local port."
      )
    }
    var next = configuration
    if let index = next.forwards.firstIndex(where: { $0.id == rule.id }) {
      next.forwards[index] = rule
    } else {
      next.forwards.append(rule)
    }
    try persist(next)
    stop(rule)
    configuration = next
    if startNow { Task { await start(rule) } }
  }

  func removeForward(_ rule: ForwardRule) {
    var next = configuration
    next.forwards.removeAll { $0.id == rule.id }
    do {
      try persist(next)
      stop(rule)
      configuration = next
    } catch { errorMessage = error.localizedDescription }
  }

  func check(_ server: ServerProfile) async {
    guard serverStates[server.id]?.isChecking != true else { return }
    serverStates[server.id] = .checking
    do {
      let info = try await ServerAPI.info(for: server)
      guard servers.contains(server) else { return }
      serverStates[server.id] = .ready(info)
    } catch {
      guard servers.contains(server) else { return }
      serverStates[server.id] = .failed(error.localizedDescription)
    }
  }

  func start(_ rule: ForwardRule) async {
    guard !starting.contains(rule.id), snapshot(rule).phase != .listening,
      let server = servers.first(where: { $0.id == rule.serverID })
    else { return }
    let requestID = UUID()
    startRequests[rule.id] = requestID
    starting.insert(rule.id)
    defer {
      if startRequests[rule.id] == requestID {
        startRequests.removeValue(forKey: rule.id)
        starting.remove(rule.id)
      }
    }
    do {
      let info = try await ServerAPI.info(for: server)
      guard startRequests[rule.id] == requestID, configuration.forwards.contains(rule),
        servers.contains(server)
      else { return }
      serverStates[server.id] = .ready(info)
      guard info.allows(rule.remotePort) else {
        throw PortsideError.invalid(
          "Remote port \(rule.remotePort) is not allowed by this server. Update its --allowed-ports setting or choose another port."
        )
      }
      try await engine.start(rule, server: server)
    } catch {
      guard startRequests[rule.id] == requestID else { return }
      errorMessage = "Could not start \(rule.name): \(error.localizedDescription)"
    }
  }

  func stop(_ rule: ForwardRule) {
    startRequests.removeValue(forKey: rule.id)
    starting.remove(rule.id)
    engine.stop(rule.id)
  }

  func stopAll() {
    startRequests.removeAll()
    starting.removeAll()
    engine.stopAll()
  }

  func restore() async {
    guard !restored else { return }
    restored = true
    for rule in configuration.forwards where rule.autoStart { await start(rule) }
  }

  func open(_ rule: ForwardRule) { NSWorkspace.shared.open(rule.browserURL) }

  func saveUploadFolder(_ folder: String, serverID: UUID) throws {
    let folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
    try UploadDestination.validateFolder(folder)
    guard let index = configuration.servers.firstIndex(where: { $0.id == serverID }) else { return }
    var next = configuration
    next.servers[index].uploadFolder = folder
    try persist(next)
    configuration = next
    if serverStates[serverID]?.isChecking == true { serverStates[serverID] = .unchecked }
  }

  func pasteFiles() {
    guard let server = selectedServer else {
      errorMessage = "Select a server before sending files."
      return
    }
    transfers.paste(server: server)
  }

  func shutdown() {
    stopAll()
    transfers.shutdown()
    hostedServer.stop()
  }

  private func persist(_ next: ClientConfiguration) throws {
    guard canSave else {
      throw PortsideError.invalid(
        "Resolve the saved configuration error before changing settings. The existing file will not be overwritten."
      )
    }
    try store.save(next)
  }
}
