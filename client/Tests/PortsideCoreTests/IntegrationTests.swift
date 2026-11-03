import Darwin
import Foundation
import Network
import XCTest

@testable import PortsideCore

@MainActor
final class IntegrationTests: XCTestCase {
  func testFilesAndImagesUploadToTheSelectedServerSubfolder() async throws {
    let server = try await RustServer.start()
    defer { server.stop() }
    var profile = server.profile
    profile.uploadFolder = "project/screenshots"
    let info = try await ServerAPI.info(for: profile)
    let settings = try XCTUnwrap(info.uploads)
    let file = server.directory.appendingPathComponent("data & preview.bin")
    let bytes = Data((0..<3 * 1024 * 1024).map { UInt8($0 % 251) })
    try bytes.write(to: file)
    let result = try await FileUploadAPI.upload(
      .file(file), to: profile, settings: settings)
    XCTAssertEqual(result.bytes, Int64(bytes.count))
    XCTAssertEqual(result.name, "data & preview.bin")
    XCTAssertTrue(result.path.hasPrefix(settings.directory + "/project/screenshots/"))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.path)), bytes)
    let imageBytes = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 255])
    let first = try await FileUploadAPI.upload(
      .image(name: "clipboard.png", data: imageBytes), to: profile,
      settings: settings)
    let second = try await FileUploadAPI.upload(
      .image(name: "clipboard.png", data: imageBytes), to: profile,
      settings: settings)
    XCTAssertNotEqual(first.path, second.path)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.path)), imageBytes)
  }

  func testClientRejectsOversizedUploadsBeforeSending() async throws {
    let server = try await RustServer.start(maxUploadBytes: 128)
    defer { server.stop() }
    let info = try await ServerAPI.info(for: server.profile)
    let settings = try XCTUnwrap(info.uploads)
    do {
      _ = try await FileUploadAPI.upload(
        .image(name: "large.png", data: Data(repeating: 7, count: 256)), to: server.profile,
        settings: settings)
      XCTFail("Oversized upload should fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("size limit")) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: settings.directory).isEmpty)
  }

  func testServerShutdownReleasesAHalfClosedTunnel() async throws {
    let server = try await RustServer.start()
    let target = try await TCPFixture.start(mode: .greetingThenRead)
    let engine = ForwardEngine()
    defer {
      engine.stopAll()
      target.stop()
      server.stop()
    }
    let rule = ForwardRule(
      serverID: server.profile.id, name: "Disconnect", localPort: try unusedPort(),
      remotePort: target.port)
    try await engine.start(rule, server: server.profile)
    let client = TCPChannel(
      NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rule.localPort)!, using: .tcp)
    )
    try await client.start()
    defer { client.cancel() }
    while !(try await client.receive()).isEOF {}
    // The local write direction is still open when the server goes away.
    server.stop()
    for _ in 0..<100 {
      if engine.snapshots[rule.id]?.connections == 0 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(engine.snapshots[rule.id]?.connections, 0)
    XCTAssertEqual(engine.snapshots[rule.id]?.phase, .listening)
    XCTAssertNotNil(engine.snapshots[rule.id]?.error)
  }

  func testTailscaleIdentityRequiredForAPI() async throws {
    let server = try await RustServer.start()
    defer { server.stop() }
    let info = try await ServerAPI.info(for: server.profile)
    XCTAssertEqual(info.authentication, "tailscale-owner")
    let peer = server.directory.appendingPathComponent("tailscale.peer")
    try Data("8".utf8).write(to: peer)
    do {
      _ = try await ServerAPI.info(for: server.profile)
      XCTFail("Another Tailscale user's device must be rejected")
    } catch PortsideError.http(403) {} catch { throw error }
    try Data("unavailable".utf8).write(to: peer)
    do {
      _ = try await ServerAPI.info(for: server.profile)
      XCTFail("An unavailable identity lookup must fail closed")
    } catch PortsideError.http(503) {} catch { throw error }
  }

  func testDynamicForwardsAreIndependentAndTransferBinary() async throws {
    let server = try await RustServer.start()
    let firstTarget = try await TCPFixture.start(mode: .echo)
    let secondTarget = try await TCPFixture.start(mode: .echo)
    let engine = ForwardEngine()
    defer {
      engine.stopAll()
      firstTarget.stop()
      secondTarget.stop()
      server.stop()
    }
    let first = ForwardRule(
      serverID: server.profile.id, name: "First", localPort: try unusedPort(),
      remotePort: firstTarget.port)
    let second = ForwardRule(
      serverID: server.profile.id, name: "Second", localPort: try unusedPort(),
      remotePort: secondTarget.port)
    try await engine.start(first, server: server.profile)
    let a = TCPChannel(
      NWConnection(
        host: "127.0.0.1", port: NWEndpoint.Port(rawValue: first.localPort)!, using: .tcp))
    try await a.start()
    try await a.send(Data("first".utf8))
    let firstReply = try await a.receive()
    XCTAssertEqual(firstReply.data, Data("first".utf8))

    try await engine.start(second, server: server.profile)
    let b = TCPChannel(
      NWConnection(
        host: "127.0.0.1", port: NWEndpoint.Port(rawValue: second.localPort)!, using: .tcp))
    try await b.start()
    defer {
      a.cancel()
      b.cancel()
    }
    engine.stop(first.id)
    XCTAssertEqual(engine.snapshots[second.id]?.phase, .listening)

    // Concurrent send and receive exercises backpressure in both directions.
    let payload = Data((0..<2_000_000).map { UInt8($0 % 251) })
    async let upload: Void = {
      for offset in stride(from: 0, to: payload.count, by: 16384) {
        try await b.send(payload.subdata(in: offset..<min(offset + 16384, payload.count)))
      }
      try await b.finishWriting()
    }()
    var received = Data()
    while true {
      let chunk = try await b.receive()
      received.append(chunk.data)
      if chunk.isEOF { break }
    }
    try await upload
    XCTAssertEqual(received, payload)
  }

  func testHTTPResponseAfterClientHalfClose() async throws {
    let server = try await RustServer.start()
    let target = try await TCPFixture.start(mode: .responseAfterEOF)
    let engine = ForwardEngine()
    defer {
      engine.stopAll()
      target.stop()
      server.stop()
    }
    let rule = ForwardRule(
      serverID: server.profile.id, name: "HTTP", localPort: try unusedPort(),
      remotePort: target.port)
    try await engine.start(rule, server: server.profile)
    let client = TCPChannel(
      NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rule.localPort)!, using: .tcp)
    )
    try await client.start()
    defer { client.cancel() }
    try await client.send(Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
    try await client.finishWriting()
    var response = Data()
    while true {
      let chunk = try await client.receive()
      response.append(chunk.data)
      if chunk.isEOF { break }
    }
    XCTAssertEqual(
      String(decoding: response, as: UTF8.self), "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
    )
  }

  func testTargetHalfClosePreservesClientWriteDirection() async throws {
    let server = try await RustServer.start()
    let target = try await TCPFixture.start(mode: .greetingThenRead)
    let engine = ForwardEngine()
    defer {
      engine.stopAll()
      target.stop()
      server.stop()
    }
    let rule = ForwardRule(
      serverID: server.profile.id, name: "Half close", localPort: try unusedPort(),
      remotePort: target.port)
    try await engine.start(rule, server: server.profile)
    let client = TCPChannel(
      NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rule.localPort)!, using: .tcp)
    )
    try await client.start()
    defer { client.cancel() }
    var greeting = Data()
    while true {
      let chunk = try await client.receive()
      greeting.append(chunk.data)
      if chunk.isEOF { break }
    }
    XCTAssertEqual(greeting, Data("greeting".utf8))
    try await client.send(Data("late response".utf8))
    try await client.finishWriting()
    for _ in 0..<50 {
      if target.received == Data("late response".utf8) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(target.received, Data("late response".utf8))
  }

  func testOccupiedLocalPortDoesNotDisruptExistingForward() async throws {
    let server = try await RustServer.start()
    let target = try await TCPFixture.start(mode: .echo)
    let engine = ForwardEngine()
    defer {
      engine.stopAll()
      target.stop()
      server.stop()
    }
    let first = ForwardRule(
      serverID: server.profile.id, name: "First", localPort: try unusedPort(),
      remotePort: target.port)
    let second = ForwardRule(
      serverID: server.profile.id, name: "Conflict", localPort: first.localPort,
      remotePort: target.port)
    try await engine.start(first, server: server.profile)
    do {
      try await engine.start(second, server: server.profile)
      XCTFail("Port conflict must fail")
    } catch { XCTAssertEqual(engine.snapshots[second.id]?.phase, .failed) }
    XCTAssertEqual(engine.snapshots[first.id]?.phase, .listening)
  }

  func testUnavailableTargetReportsErrorAndKeepsListenerRunning() async throws {
    let server = try await RustServer.start()
    let engine = ForwardEngine()
    defer {
      engine.stopAll()
      server.stop()
    }
    let rule = ForwardRule(
      serverID: server.profile.id, name: "Unavailable", localPort: try unusedPort(),
      remotePort: try unusedPort())
    try await engine.start(rule, server: server.profile)
    let client = TCPChannel(
      NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rule.localPort)!, using: .tcp)
    )
    try await client.start()
    defer { client.cancel() }
    for _ in 0..<100 {
      if engine.snapshots[rule.id]?.error != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(engine.snapshots[rule.id]?.phase, .listening)
    XCTAssertTrue(engine.snapshots[rule.id]?.error?.contains("not listening") == true)
  }
}

@MainActor
private final class RustServer {
  let profile: ServerProfile
  let process: Process
  let directory: URL

  private init(profile: ServerProfile, process: Process, directory: URL) {
    self.profile = profile
    self.process = process
    self.directory = directory
  }

  static func start(maxUploadBytes: Int = 100 * 1024 * 1024) async throws -> RustServer {
    guard let binary = ProcessInfo.processInfo.environment["PORTSIDE_TEST_SERVER"] else {
      throw XCTSkip("Set PORTSIDE_TEST_SERVER to the Rust release binary to run end-to-end tests.")
    }
    let port = try unusedPort()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "portside-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let identityFixture = ProcessInfo.processInfo.environment["PORTSIDE_TEST_TAILSCALE"]
    else {
      throw XCTSkip("Set PORTSIDE_TEST_TAILSCALE to the test identity fixture.")
    }
    let identity = directory.appendingPathComponent("tailscale.py")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: identityFixture), to: identity)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [
      "serve", "--listen", "127.0.0.1:\(port)", "--tailscale-bin", identity.path,
      "--upload-dir", directory.appendingPathComponent("uploads").path, "--max-upload-bytes",
      String(maxUploadBytes),
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let server = RustServer(
      profile: ServerProfile(name: "Test", host: "127.0.0.1", port: port), process: process,
      directory: directory)
    do {
      try process.run()
      for _ in 0..<30 {
        do {
          _ = try await ServerAPI.info(for: server.profile)
          return server
        } catch { try await Task.sleep(for: .milliseconds(50)) }
      }
      throw PortsideError.invalid("Rust test server did not become ready.")
    } catch {
      server.stop()
      throw error
    }
  }

  func stop() {
    if process.isRunning { process.terminate() }
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor
private final class TCPFixture {
  enum Mode { case echo, responseAfterEOF, greetingThenRead }
  let listener: NWListener
  let port: UInt16
  private var channels: [TCPChannel] = []
  private var tasks: [Task<Void, Never>] = []
  private(set) var received = Data()

  private init(listener: NWListener, port: UInt16) {
    self.listener = listener
    self.port = port
  }

  static func start(mode: Mode) async throws -> TCPFixture {
    let listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { $0.cancel() }
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: continuation.resume()
        case .failed(let error): continuation.resume(throwing: error)
        default: break
        }
      }
      listener.start(queue: DispatchQueue(label: "app.portside.test-fixture"))
    }
    listener.stateUpdateHandler = nil
    let fixture = TCPFixture(listener: listener, port: listener.port!.rawValue)
    listener.newConnectionHandler = { [weak fixture] connection in
      Task { @MainActor in
        guard let fixture else {
          connection.cancel()
          return
        }
        let channel = TCPChannel(connection)
        fixture.channels.append(channel)
        fixture.tasks.append(
          Task { @MainActor in
            do {
              try await channel.start()
              if mode == .greetingThenRead {
                try await channel.send(Data("greeting".utf8))
                try await channel.finishWriting()
              }
              while true {
                let chunk = try await channel.receive()
                fixture.received.append(chunk.data)
                if mode == .echo, !chunk.data.isEmpty { try await channel.send(chunk.data) }
                if chunk.isEOF { break }
              }
              if mode == .responseAfterEOF {
                try await channel.send(
                  Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8))
              }
              if mode != .greetingThenRead { try await channel.finishWriting() }
            } catch {}
          })
      }
    }
    return fixture
  }

  func stop() {
    listener.cancel()
    for task in tasks { task.cancel() }
    for channel in channels { channel.cancel() }
  }
}

private func unusedPort() throws -> UInt16 {
  let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw PortsideError.invalid("Cannot allocate a test socket.") }
  defer { Darwin.close(descriptor) }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard result == 0 else { throw PortsideError.invalid("Cannot bind test socket.") }
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let status = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
  }
  guard status == 0 else { throw PortsideError.invalid("Cannot read test socket address.") }
  return UInt16(bigEndian: address.sin_port)
}
