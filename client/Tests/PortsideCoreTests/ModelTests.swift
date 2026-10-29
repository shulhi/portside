import Foundation
import XCTest

@testable import PortsideCore

final class ModelTests: XCTestCase {
  func testOnlyTailnetOrLoopbackHostsAreAccepted() {
    for host in [
      "127.0.0.1", "::1", "localhost", "100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1",
      "work-laptop", "work.example.ts.net",
    ] {
      XCTAssertTrue(ServerProfile.isPrivateHost(host), host)
    }
    for host in [
      "", "0.0.0.0", "::", "192.168.1.5", "8.8.8.8", "100.63.255.255", "100.128.0.1", "example.com",
      "http://work:9417", "work:9417", "work/path", "work..ts.net", "-bad", "999.999.999.999",
    ] {
      XCTAssertFalse(ServerProfile.isPrivateHost(host), host)
    }
  }

  func testIPv6AndMagicDNSURLs() throws {
    let ipv6 = ServerProfile(name: "Work", host: "fd7a:115c:a1e0::1")
    XCTAssertEqual(
      try ipv6.url(path: "/v1/info").absoluteString, "http://[fd7a:115c:a1e0::1]:9417/v1/info")
    let dns = ServerProfile(name: "Work", host: "work-laptop")
    XCTAssertEqual(
      try dns.url(path: "/v1/tunnels/5173", websocket: true, family: .ipv6).absoluteString,
      "ws://work-laptop:9417/v1/tunnels/5173?family=ipv6")
  }

  func testTokenValidation() throws {
    XCTAssertEqual(
      try TokenVault.validate(" \n" + String(repeating: "a", count: 64) + "\n"),
      String(repeating: "a", count: 64))
    XCTAssertThrowsError(try TokenVault.validate("short"))
    XCTAssertThrowsError(try TokenVault.validate(String(repeating: "z", count: 64)))
  }

  func testBinaryFrameLimitsAndEOF() throws {
    let binary = Data((0...255).map(UInt8.init))
    XCTAssertEqual(try TunnelFrame(decoding: TunnelFrame.data(binary).encoded()), .data(binary))
    XCTAssertEqual(try TunnelFrame(decoding: Data([1])), .eof)
    XCTAssertEqual(try TunnelFrame(decoding: Data([0])), .data(Data()))
    for invalid in [Data(), Data([2]), Data([1, 0]), Data(repeating: 0, count: 65538)] {
      XCTAssertThrowsError(try TunnelFrame(decoding: invalid))
    }
    XCTAssertThrowsError(try TunnelFrame.data(Data(repeating: 0, count: 65537)).encoded())
  }

  func testServerPortPolicyHonorsExclusions() throws {
    let json = """
      {"name":"portside-server","version":"0.1.0","protocol":"portside.tcp.v1","allowed_ports":["3000","8000-8100","9417"],"excluded_ports":[9417],"max_tunnels":128,"active_tunnels":0,"max_data_size":65536}
      """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let info = try decoder.decode(ServerInfo.self, from: Data(json.utf8))
    for port: UInt16 in [3000, 8000, 8100] { XCTAssertTrue(info.allows(port)) }
    for port: UInt16 in [0, 7999, 8101, 9417] { XCTAssertFalse(info.allows(port)) }
  }

  func testConfigurationRoundTripContainsNoCredentials() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(fileURL: directory.appendingPathComponent("config.json"))
    XCTAssertEqual(try store.load(), ClientConfiguration())
    let server = ServerProfile(name: "Work", host: "work")
    let rule = ForwardRule(
      serverID: server.id, name: "App", localPort: 3000, remotePort: 5173, autoStart: true)
    let config = ClientConfiguration(servers: [server], forwards: [rule])
    try store.save(config)
    XCTAssertEqual(try store.load(), config)
    XCTAssertFalse(
      try String(contentsOf: store.fileURL, encoding: .utf8).lowercased().contains("token"))
    try Data("corrupt".utf8).write(to: store.fileURL)
    XCTAssertThrowsError(try store.load())
    XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "corrupt")
  }

  func testLocalPortsAreUnprivilegedAndTargetPortCanBePrivileged() throws {
    let valid = ForwardRule(serverID: UUID(), name: "App", localPort: 3000, remotePort: 80)
    XCTAssertNoThrow(try valid.validate())
    XCTAssertEqual(valid.browserURL.absoluteString, "http://localhost:3000")
    XCTAssertThrowsError(
      try ForwardRule(serverID: UUID(), name: "App", localPort: 80, remotePort: 3000).validate())
  }
}
