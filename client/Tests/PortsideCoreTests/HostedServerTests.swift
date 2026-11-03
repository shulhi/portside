import Darwin
import Foundation
import XCTest

@testable import PortsideCore

@MainActor
final class HostedServerTests: XCTestCase {
  func testHostingOnlyAcceptsPrivateLiteralAddressesAndValidPortPolicies() throws {
    for address in ["127.0.0.1", "::1", "100.64.0.1", "fd7a:115c:a1e0::1"] {
      XCTAssertNoThrow(try HostedServerConfiguration(address: address).validate())
    }
    for address in ["", "0.0.0.0", "::", "192.168.1.2", "8.8.8.8", "work-mac", "localhost"] {
      XCTAssertThrowsError(try HostedServerConfiguration(address: address).validate(), address)
    }
    for ports in ["", "0", "3000,", "8000-7999", "65536", "22-", "-22", "3000\n"] {
      XCTAssertThrowsError(
        try HostedServerConfiguration(address: "127.0.0.1", allowedPorts: ports).validate(), ports)
    }
    XCTAssertNoThrow(
      try HostedServerConfiguration(address: "127.0.0.1", allowedPorts: "3000, 8000-9000")
        .validate())
  }

  func testHostedServerUsesTailscaleIdentityPersistsSettingsAndStops() async throws {
    let binary = try executable()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "portside-host-\(UUID().uuidString)")
    let host = HostedServer(
      directory: directory, executableURL: binary, tailscaleURL: try identityFixture())
    defer {
      host.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    let (reservation, port) = try listeningSocket()
    close(reservation)
    let config = HostedServerConfiguration(
      address: "127.0.0.1", port: port, allowedPorts: "3000,5173,8080")
    try await host.start(config)
    XCTAssertEqual(host.phase, .running)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("server.token").path))
    let directoryPermissions =
      try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(directoryPermissions?.intValue, 0o700)
    let profile = ServerProfile(name: "Hosted", host: config.address, port: port)
    let info = try await ServerAPI.info(for: profile)
    XCTAssertTrue(info.allows(3000))
    XCTAssertFalse(info.allows(5432))
    XCTAssertNil(info.uploads)
    host.stop()
    try await awaitStopped(host)
    let reloaded = HostedServer(
      directory: directory, executableURL: binary, tailscaleURL: try identityFixture())
    defer { reloaded.stop() }
    XCTAssertEqual(reloaded.configuration, config)
    try await reloaded.start(config)
    XCTAssertEqual(reloaded.phase, .running)
    reloaded.stop()
    try await awaitStopped(reloaded)
  }

  func testBindFailureLeavesExistingListenerAloneAndReportsFailure() async throws {
    let binary = try executable()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "portside-host-failure-\(UUID().uuidString)")
    let host = HostedServer(
      directory: directory, executableURL: binary, tailscaleURL: try identityFixture())
    let (listener, port) = try listeningSocket()
    defer {
      close(listener)
      host.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    do {
      try await host.start(HostedServerConfiguration(address: "127.0.0.1", port: port))
      XCTFail("An occupied port must not report a successful startup")
    } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    XCTAssertEqual(host.phase, .failed)
    XCTAssertNotNil(host.errorMessage)
    XCTAssertGreaterThanOrEqual(fcntl(listener, F_GETFD), 0)
  }

  private func identityFixture() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["PORTSIDE_TEST_TAILSCALE"] else {
      throw XCTSkip("Run scripts/test.sh to use the isolated Tailscale identity fixture.")
    }
    return URL(fileURLWithPath: path)
  }

  private func executable() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["PORTSIDE_TEST_SERVER"] else {
      throw XCTSkip("Run scripts/test.sh to test the bundled Rust server lifecycle.")
    }
    return URL(fileURLWithPath: path)
  }

  private func awaitStopped(_ host: HostedServer) async throws {
    for _ in 0..<150 {
      if host.phase == .stopped { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("The hosted server did not stop after its supervisor pipe closed")
  }

  private func listeningSocket() throws -> (Int32, UInt16) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw PortsideError.invalid("Cannot create test socket.") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard bound == 0, named == 0, listen(descriptor, 4) == 0 else {
      close(descriptor)
      throw PortsideError.invalid("Cannot bind test socket.")
    }
    return (descriptor, UInt16(bigEndian: address.sin_port))
  }
}
