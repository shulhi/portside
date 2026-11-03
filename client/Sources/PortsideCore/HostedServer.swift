import Combine
import Darwin
import Foundation

public struct HostedServerConfiguration: Codable, Equatable, Sendable {
  public var address: String
  public var port: UInt16
  public var allowedPorts: String

  public init(address: String = "", port: UInt16 = 9417, allowedPorts: String = "3000,5173,8080") {
    self.address = address
    self.port = port
    self.allowedPorts = allowedPorts
  }

  public var endpoint: String {
    address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
  }

  public func validate() throws {
    var v4 = in_addr()
    var v6 = in6_addr()
    let literal = address.withCString {
      inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1
    }
    guard literal, ServerProfile.isPrivateHost(address), port > 0 else {
      throw PortsideError.invalid(
        "Choose this Mac's Tailscale IP, or a loopback IP for local testing, and a nonzero server port."
      )
    }
    let entries = allowedPorts.split(separator: ",", omittingEmptySubsequences: false)
    guard !entries.isEmpty,
      entries.allSatisfy({ entry in
        let bounds = entry.trimmingCharacters(in: .whitespaces).split(
          separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(bounds.count), let first = UInt16(bounds[0]), first > 0 else {
          return false
        }
        return bounds.count == 1 || (UInt16(bounds[1]).map { $0 >= first } ?? false)
      })
    else {
      throw PortsideError.invalid(
        "Enter ports such as 3000,5173,8080 or a range such as 8000-9000.")
    }
  }

  public static func tailscaleAddresses() -> [String] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0 else { return [] }
    defer { freeifaddrs(interfaces) }
    var addresses = Set<String>()
    var current = interfaces
    while let item = current {
      defer { current = item.pointee.ifa_next }
      guard let address = item.pointee.ifa_addr,
        (Int32(item.pointee.ifa_flags) & IFF_UP) != 0,
        address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6)
      else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(
        address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0,
        NI_NUMERICHOST) == 0
      {
        let value = String(
          decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if ServerProfile.isPrivateHost(value), !value.hasPrefix("127."), value != "::1" {
          addresses.insert(value)
        }
      }
    }
    return addresses.sorted { lhs, rhs in
      if lhs.contains(":") != rhs.contains(":") { return !lhs.contains(":") }
      return lhs < rhs
    }
  }
}

public enum HostedServerPhase: Equatable, Sendable {
  case stopped, starting, running, stopping, failed
  public var isActive: Bool { self == .starting || self == .running || self == .stopping }
}

/// Supervises the bundled Rust server without disturbing this app's client forwards.
@MainActor
public final class HostedServer: ObservableObject {
  @Published public private(set) var phase: HostedServerPhase = .stopped
  @Published public private(set) var configuration = HostedServerConfiguration()
  @Published public private(set) var errorMessage: String?
  public let directory: URL
  public var tokenURL: URL { directory.appendingPathComponent("server.token") }
  private var settingsURL: URL { directory.appendingPathComponent("configuration.json") }
  private var logURL: URL { directory.appendingPathComponent("server.log") }
  private let executableURL: URL
  private var process: Process?
  private var generator: Process?
  private var parentPipe: Pipe?
  private var operation: UUID?
  private var canSave = true

  public init(directory: URL? = nil, executableURL: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Portside/Host", isDirectory: true)
    self.executableURL =
      executableURL
      ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/portside-server")
    do {
      if FileManager.default.fileExists(atPath: settingsURL.path) {
        configuration = try JSONDecoder().decode(
          HostedServerConfiguration.self, from: Data(contentsOf: settingsURL))
      }
    } catch {
      canSave = false
      errorMessage =
        "Hosting settings could not be read. The existing file has been preserved: \(settingsURL.path)"
    }
  }

  public func token() throws -> String {
    try TokenVault.validate(String(contentsOf: tokenURL, encoding: .utf8))
  }

  public func start(_ settings: HostedServerConfiguration) async throws {
    guard !phase.isActive, process == nil else { return }
    try settings.validate()
    guard canSave else {
      throw PortsideError.invalid(errorMessage ?? "Resolve the hosting settings error first.")
    }
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw PortsideError.invalid(
        "The bundled server is missing. Build and open Portside.app using scripts/build-app.sh.")
    }
    let request = UUID()
    operation = request
    phase = .starting
    errorMessage = nil
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
      configuration = settings
      FileManager.default.createFile(
        atPath: logURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
      let output = try FileHandle(forWritingTo: logURL)
      defer { try? output.close() }
      if !FileManager.default.fileExists(atPath: tokenURL.path) {
        let child = Process()
        child.executableURL = executableURL
        child.environment = ["RUST_LOG": "info"]
        child.arguments = ["generate-token", "--output", tokenURL.path]
        child.standardOutput = output
        child.standardError = output
        generator = child
        try child.run()
        while child.isRunning {
          try await Task.sleep(for: .milliseconds(20))
          guard operation == request else { return }
        }
        generator = nil
        guard child.terminationStatus == 0 else { throw PortsideError.invalid(failureLog()) }
      }
      guard operation == request else { return }
      let credential = try token()
      let child = Process()
      let pipe = Pipe()
      child.executableURL = executableURL
      child.environment = ["RUST_LOG": "info"]
      child.arguments = [
        "serve", "--listen", settings.endpoint, "--token-file", tokenURL.path,
        "--allowed-ports", settings.allowedPorts, "--shutdown-on-stdin-eof",
      ]
      child.standardInput = pipe
      child.standardOutput = output
      child.standardError = output
      child.terminationHandler = { [weak self] exited in
        Task { @MainActor in self?.didExit(exited, request: request) }
      }
      process = child
      parentPipe = pipe
      try child.run()
      // Parent retains only the writer. Closing it, including on app crash, stops Rust.
      try? pipe.fileHandleForReading.close()
      let profile = ServerProfile(name: "This Mac", host: settings.address, port: settings.port)
      let sessionConfig = URLSessionConfiguration.ephemeral
      sessionConfig.timeoutIntervalForRequest = 1
      sessionConfig.timeoutIntervalForResource = 1
      sessionConfig.httpCookieStorage = nil
      sessionConfig.urlCache = nil
      let session = URLSession(configuration: sessionConfig)
      defer { session.invalidateAndCancel() }
      let deadline = ContinuousClock.now + .seconds(6)
      while operation == request, child.isRunning, ContinuousClock.now < deadline {
        do {
          var health = URLRequest(url: try profile.url(path: "/v1/info"))
          health.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
          let (data, response) = try await session.data(for: health)
          if (response as? HTTPURLResponse)?.statusCode == 200 {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let info = try decoder.decode(ServerInfo.self, from: data)
            guard info.protocol == TunnelFrame.subprotocol else {
              throw PortsideError.protocolMismatch
            }
            guard operation == request, child.isRunning else { return }
            phase = .running
            return
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // The process may still be binding; retry within the deadline.
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard operation == request else { return }
      throw PortsideError.invalid(failureLog())
    } catch {
      guard operation == request else { return }
      operation = nil
      try? parentPipe?.fileHandleForWriting.close()
      parentPipe = nil
      if generator?.isRunning == true { generator?.terminate() }
      generator = nil
      if process?.isRunning == true { process?.terminate() }
      process = nil
      phase = .failed
      errorMessage = error.localizedDescription
      throw error
    }
  }

  public func stop() {
    operation = nil
    if generator?.isRunning == true { generator?.terminate() }
    generator = nil
    try? parentPipe?.fileHandleForWriting.close()
    parentPipe = nil
    phase = process?.isRunning == true ? .stopping : .stopped
  }

  private func didExit(_ child: Process, request: UUID) {
    guard process === child else { return }
    process = nil
    try? parentPipe?.fileHandleForWriting.close()
    parentPipe = nil
    if operation == request {
      phase = .failed
      errorMessage = failureLog()
    } else if phase != .failed {
      phase = .stopped
    }
  }

  private func failureLog() -> String {
    let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    let summary = log.split(separator: "\n").suffix(4).joined(separator: "\n")
    return summary.isEmpty
      ? "The server did not become ready. Check that Tailscale is connected, the IP belongs to this Mac, and the port is free."
      : String(summary.suffix(2000))
  }
}
