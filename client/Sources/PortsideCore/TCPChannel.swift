import Foundation
import Network

@MainActor
final class TCPChannel {
  struct Chunk: Sendable {
    let data: Data
    let isEOF: Bool
  }
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "app.portside.tcp")
  private var opening: CheckedContinuation<Void, any Error>?
  private var cancelled = false

  init(_ connection: NWConnection) { self.connection = connection }

  func start() async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      guard !cancelled else {
        continuation.resume(throwing: CancellationError())
        return
      }
      opening = continuation
      connection.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          guard let self else { return }
          switch state {
          case .ready: self.finishOpening(nil)
          case .failed(let error): self.finishOpening(error)
          case .cancelled: self.finishOpening(CancellationError())
          default: break
          }
        }
      }
      connection.start(queue: queue)
    }
  }

  func receive() async throws -> Chunk {
    guard !cancelled else { throw CancellationError() }
    return try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
        data, _, complete, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: Chunk(data: data ?? Data(), isEOF: complete))
        }
      }
    }
  }

  func send(_ data: Data) async throws {
    guard !cancelled else { throw CancellationError() }
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
  }

  func finishWriting() async throws {
    guard !cancelled else { throw CancellationError() }
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: nil, contentContext: .finalMessage, isComplete: true,
        completion: .contentProcessed { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
  }

  func cancel() {
    cancelled = true
    finishOpening(CancellationError())
    connection.cancel()
  }

  private func finishOpening(_ error: (any Error)?) {
    guard let continuation = opening else { return }
    opening = nil
    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
  }
}
