import Foundation

@MainActor
final class WebSocketChannel: NSObject, URLSessionWebSocketDelegate {
  var onFailure: ((any Error) -> Void)?
  private var session: URLSession?
  private var socket: URLSessionWebSocketTask?
  private var opening: CheckedContinuation<Void, any Error>?
  private var deadline: Task<Void, Never>?
  private var closed = false

  func connect(profile: ServerProfile, rule: ForwardRule) async throws {
    var request = URLRequest(
      url: try profile.url(
        path: "/v1/tunnels/\(rule.remotePort)", websocket: true, family: rule.family))
    request.setValue(TunnelFrame.subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    self.session = session
    let socket = session.webSocketTask(with: request)
    socket.maximumMessageSize = TunnelFrame.maximumDataSize + 1
    self.socket = socket
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      guard !closed else {
        continuation.resume(throwing: CancellationError())
        return
      }
      opening = continuation
      deadline = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        self?.finishOpening(URLError(.timedOut))
        self?.close()
      }
      socket.resume()
    }
  }

  func send(_ frame: TunnelFrame) async throws {
    guard let socket, !closed else { throw PortsideError.disconnected }
    try await socket.send(.data(try frame.encoded()))
  }

  func receive() async throws -> TunnelFrame {
    guard let socket, !closed else { throw PortsideError.disconnected }
    switch try await socket.receive() {
    case .data(let data): return try TunnelFrame(decoding: data)
    case .string: throw PortsideError.invalid("The server sent a text frame instead of TCP data.")
    @unknown default: throw PortsideError.protocolMismatch
    }
  }

  func close() {
    closed = true
    finishOpening(CancellationError())
    socket?.cancel(with: .normalClosure, reason: nil)
    session?.invalidateAndCancel()
    session = nil
    socket = nil
  }

  private func finishOpening(_ error: (any Error)?) {
    deadline?.cancel()
    deadline = nil
    guard let continuation = opening else { return }
    opening = nil
    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
  }

  nonisolated func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if `protocol` == TunnelFrame.subprotocol {
        self.finishOpening(nil)
      } else {
        self.finishOpening(PortsideError.protocolMismatch)
        self.close()
      }
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    Task { @MainActor [weak self] in
      guard let self, !self.closed else { return }
      self.finishOpening(PortsideError.disconnected)
      if closeCode != .normalClosure { self.onFailure?(PortsideError.disconnected) }
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let status = (task.response as? HTTPURLResponse)?.statusCode
    Task { @MainActor [weak self] in
      guard let self, !self.closed else { return }
      if let status, status != 101 {
        self.finishOpening(PortsideError.http(status))
        self.onFailure?(PortsideError.http(status))
      } else {
        self.finishOpening(error ?? PortsideError.disconnected)
        if let error { self.onFailure?(error) }
      }
    }
  }
}
