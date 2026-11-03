import Combine
import Foundation
import Network

public enum ForwardPhase: String, Sendable { case stopped, starting, listening, failed }

public struct ForwardSnapshot: Sendable {
  public var phase: ForwardPhase = .stopped
  public var connections: Int = 0
  public var sentBytes: UInt64 = 0
  public var receivedBytes: UInt64 = 0
  public var error: String?
  public init() {}
}

@MainActor
public final class ForwardEngine: ObservableObject {
  @Published public private(set) var snapshots: [UUID: ForwardSnapshot] = [:]
  private var listeners: [UUID: ForwardListener] = [:]
  public init() {}

  public func start(_ rule: ForwardRule, server: ServerProfile) async throws {
    try rule.validate()
    try server.validate()
    guard rule.serverID == server.id else {
      throw PortsideError.invalid("This forward belongs to a different server.")
    }
    if let previous = listeners[rule.id] {
      guard snapshots[rule.id]?.phase == .failed else { return }
      listeners.removeValue(forKey: rule.id)
      previous.stop()
    }
    let listener = try ForwardListener(rule: rule, server: server) {
      [weak self] snapshot in
      self?.snapshots[rule.id] = snapshot
    }
    listeners[rule.id] = listener
    do { try await listener.start() } catch {
      if listeners[rule.id] === listener { listeners.removeValue(forKey: rule.id) }
      listener.stop(error: error)
      throw error
    }
  }

  public func stop(_ id: UUID) {
    listeners.removeValue(forKey: id)?.stop()
    snapshots[id] = ForwardSnapshot()
  }

  public func stopAll() {
    for id in Array(listeners.keys) { stop(id) }
  }
}

@MainActor
private final class ForwardListener {
  private let listener: NWListener
  private let rule: ForwardRule
  private let server: ServerProfile
  private let queue = DispatchQueue(label: "app.portside.listener")
  private let changed: (ForwardSnapshot) -> Void
  private var snapshot = ForwardSnapshot()
  private var opening: CheckedContinuation<Void, any Error>?
  private var tunnels: [UUID: Tunnel] = [:]
  private var stopped = false

  init(
    rule: ForwardRule, server: ServerProfile,
    changed: @escaping (ForwardSnapshot) -> Void
  ) throws {
    self.rule = rule
    self.server = server
    self.changed = changed
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: rule.localPort)!)
    parameters.allowLocalEndpointReuse = false
    self.listener = try NWListener(using: parameters)
  }

  func start() async throws {
    snapshot.phase = .starting
    changed(snapshot)
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      guard !stopped else {
        continuation.resume(throwing: CancellationError())
        return
      }
      opening = continuation
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in self?.stateChanged(state) }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in
          guard let self, !self.stopped else {
            connection.cancel()
            return
          }
          self.accept(connection)
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop(error: (any Error)? = nil) {
    guard !stopped else { return }
    stopped = true
    listener.cancel()
    let continuation = opening
    opening = nil
    continuation?.resume(throwing: error ?? CancellationError())
    let active = Array(tunnels.values)
    tunnels.removeAll()
    for tunnel in active { tunnel.cancel() }
    snapshot.phase = error == nil ? .stopped : .failed
    snapshot.connections = 0
    snapshot.error = error?.localizedDescription
    changed(snapshot)
  }

  private func stateChanged(_ state: NWListener.State) {
    guard !stopped else { return }
    switch state {
    case .ready:
      snapshot.phase = .listening
      changed(snapshot)
      let continuation = opening
      opening = nil
      continuation?.resume()
    case .failed(let error): stop(error: error)
    case .waiting(let error): stop(error: error)
    default: break
    }
  }

  private func accept(_ connection: NWConnection) {
    guard tunnels.count < 128 else {
      connection.cancel()
      snapshot.error = "Too many connections on this forward."
      changed(snapshot)
      return
    }
    let id = UUID()
    let tunnel = Tunnel(
      connection: connection, server: server, rule: rule,
      traffic: { [weak self] sent, received in
        guard let self, !self.stopped else { return }
        self.snapshot.sentBytes += UInt64(sent)
        self.snapshot.receivedBytes += UInt64(received)
        self.changed(self.snapshot)
      },
      finished: { [weak self] error in
        guard let self, !self.stopped else { return }
        self.tunnels.removeValue(forKey: id)
        self.snapshot.connections = self.tunnels.count
        if let error { self.snapshot.error = error.localizedDescription }
        self.changed(self.snapshot)
      })
    tunnels[id] = tunnel
    snapshot.connections = tunnels.count
    snapshot.error = nil
    changed(snapshot)
    tunnel.start()
  }
}

@MainActor
private final class Tunnel {
  private let tcp: TCPChannel
  private let websocket = WebSocketChannel()
  private let server: ServerProfile
  private let rule: ForwardRule
  private let traffic: (Int, Int) -> Void
  private let finished: ((any Error)?) -> Void
  private var task: Task<Void, Never>?
  private var cancelled = false
  private var transportFailure: (any Error)?
  private var sentEOF = false
  private var receivedEOF = false

  init(
    connection: NWConnection, server: ServerProfile, rule: ForwardRule,
    traffic: @escaping (Int, Int) -> Void, finished: @escaping ((any Error)?) -> Void
  ) {
    tcp = TCPChannel(connection)
    self.server = server
    self.rule = rule
    self.traffic = traffic
    self.finished = finished
  }

  func start() {
    websocket.onFailure = { [weak self] error in
      self?.transportFailure = error
      self?.tcp.cancel()
    }
    task = Task { [self] in
      var failure: (any Error)?
      do {
        try Task.checkCancellation()
        try await tcp.start()
        try Task.checkCancellation()
        try await websocket.connect(profile: server, rule: rule)
        try Task.checkCancellation()
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { [self] in try await self.upload() }
          group.addTask { [self] in try await self.download() }
          do { for try await _ in group {} } catch {
            group.cancelAll()
            tcp.cancel()
            websocket.close()
            throw error
          }
        }
      } catch { if !cancelled { failure = transportFailure ?? error } }
      tcp.cancel()
      websocket.close()
      finished(failure)
      task = nil
    }
  }

  func cancel() {
    cancelled = true
    task?.cancel()
    tcp.cancel()
    websocket.close()
  }

  private func upload() async throws {
    while true {
      try Task.checkCancellation()
      let chunk = try await tcp.receive()
      if !chunk.data.isEmpty {
        try await websocket.send(.data(chunk.data))
        traffic(chunk.data.count, 0)
      }
      if chunk.isEOF {
        try await websocket.send(.eof)
        sentEOF = true
        if receivedEOF { websocket.close() }
        return
      }
    }
  }

  private func download() async throws {
    while true {
      try Task.checkCancellation()
      let frame: TunnelFrame
      do { frame = try await websocket.receive() } catch {
        if sentEOF && receivedEOF { return }
        throw error
      }
      switch frame {
      case .data(let data):
        guard !receivedEOF else {
          throw PortsideError.invalid("The server sent data after closing its TCP direction.")
        }
        if !data.isEmpty {
          try await tcp.send(data)
          traffic(0, data.count)
        }
      case .eof:
        guard !receivedEOF else {
          throw PortsideError.invalid("The server sent duplicate TCP EOF frames.")
        }
        receivedEOF = true
        try await tcp.finishWriting()
        if sentEOF { return }
      // Keep receiving control frames until the other direction ends.
      // Foundation does not deliver peer closure while receive is idle.
      }
    }
  }
}
