import Darwin
import Foundation

public enum PortsideError: LocalizedError, Sendable {
  case invalid(String)
  case http(Int)
  case protocolMismatch
  case disconnected
  case keychain(Int32)

  public var errorDescription: String? {
    switch self {
    case .invalid(let message): message
    case .http(401): "The server rejected this token. Update the token in server settings."
    case .http(403): "The server denied access. Check its allowed ports and access settings."
    case .http(502): "The remote app is not listening on this port. Start it on your work server."
    case .http(503): "The server is busy or shutting down. Try again shortly."
    case .http(504): "Connecting to the remote app timed out."
    case .http(let status): "The server returned HTTP \(status)."
    case .protocolMismatch: "This server uses an incompatible Portside protocol."
    case .disconnected: "The connection closed before the tunnel finished."
    case .keychain(let status): "Keychain could not access the server token (\(status))."
    }
  }
}

public enum LoopbackFamily: String, Codable, CaseIterable, Sendable {
  case ipv4, ipv6
  public var title: String { self == .ipv4 ? "IPv4 · 127.0.0.1" : "IPv6 · ::1" }
}

public struct ServerProfile: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var host: String
  public var port: UInt16
  public var uploadFolder: String

  public init(
    id: UUID = UUID(), name: String, host: String, port: UInt16 = 9417, uploadFolder: String = ""
  ) {
    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    self.port = port
    self.uploadFolder = uploadFolder.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private enum CodingKeys: String, CodingKey { case id, name, host, port, uploadFolder }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    host = try values.decode(String.self, forKey: .host)
    port = try values.decode(UInt16.self, forKey: .port)
    uploadFolder = try values.decodeIfPresent(String.self, forKey: .uploadFolder) ?? ""
  }

  public func validate() throws {
    try UploadDestination.validateFolder(uploadFolder)
    guard !name.isEmpty else { throw PortsideError.invalid("Give this server a name.") }
    guard port > 0 else {
      throw PortsideError.invalid("The server port must be between 1 and 65535.")
    }
    guard Self.isPrivateHost(host) else {
      throw PortsideError.invalid(
        "Use a Tailscale IP, a short MagicDNS name, a .ts.net name, or localhost. Enter the host without a URL or port."
      )
    }
  }

  public static func isPrivateHost(_ host: String) -> Bool {
    if host == "localhost" { return true }
    var v4 = in_addr()
    if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
      let bytes = withUnsafeBytes(of: &v4.s_addr) { Array($0) }
      return bytes[0] == 127 || (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }
    var v6 = in6_addr()
    if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
      let bytes = withUnsafeBytes(of: &v6) { Array($0) }
      return bytes == Array(repeating: UInt8(0), count: 15) + [1]
        || Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }
    // Reject numeric dotted addresses that failed inet_pton, and URL syntax.
    guard !host.isEmpty, host.count <= 253, !host.allSatisfy({ $0.isNumber || $0 == "." }) else {
      return false
    }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard
      labels.allSatisfy({ label in
        !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
          && label.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
          }
      })
    else { return false }
    return labels.count == 1 || host.lowercased().hasSuffix(".ts.net")
  }

  public func url(path: String, websocket: Bool = false, family: LoopbackFamily? = nil) throws
    -> URL
  {
    try validate()
    var components = URLComponents()
    components.scheme = websocket ? "ws" : "http"
    components.host = host.contains(":") ? "[\(host)]" : host
    components.port = Int(port)
    components.path = path
    if let family { components.queryItems = [URLQueryItem(name: "family", value: family.rawValue)] }
    guard let url = components.url else {
      throw PortsideError.invalid("The server address is invalid.")
    }
    return url
  }
}

public struct ForwardRule: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var serverID: UUID
  public var name: String
  public var localPort: UInt16
  public var remotePort: UInt16
  public var family: LoopbackFamily
  public var autoStart: Bool

  public init(
    id: UUID = UUID(), serverID: UUID, name: String, localPort: UInt16, remotePort: UInt16,
    family: LoopbackFamily = .ipv4, autoStart: Bool = false
  ) {
    self.id = id
    self.serverID = serverID
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.localPort = localPort
    self.remotePort = remotePort
    self.family = family
    self.autoStart = autoStart
  }

  public func validate() throws {
    guard !name.isEmpty else { throw PortsideError.invalid("Give this forward a name.") }
    guard localPort >= 1024 else {
      throw PortsideError.invalid("Choose a local port between 1024 and 65535.")
    }
    guard remotePort > 0 else {
      throw PortsideError.invalid("Choose a remote port between 1 and 65535.")
    }
  }

  public var browserURL: URL { URL(string: "http://localhost:\(localPort)")! }
}

public struct ServerInfo: Decodable, Sendable {
  public let name: String
  public let version: String
  public let `protocol`: String
  public let allowedPorts: [String]
  public let excludedPorts: [UInt16]
  public let maxTunnels: Int
  public let activeTunnels: Int
  public let maxDataSize: Int
  public let uploads: UploadSettings?

  public func allows(_ port: UInt16) -> Bool {
    guard port > 0, !excludedPorts.contains(port) else { return false }
    return allowedPorts.contains { entry in
      let bounds = entry.split(separator: "-", omittingEmptySubsequences: false)
      if bounds.count == 1 { return UInt16(entry) == port }
      guard bounds.count == 2, let lower = UInt16(bounds[0]), let upper = UInt16(bounds[1]) else {
        return false
      }
      return lower <= port && port <= upper
    }
  }
}

public struct ClientConfiguration: Codable, Equatable, Sendable {
  public var servers: [ServerProfile]
  public var forwards: [ForwardRule]
  public init(servers: [ServerProfile] = [], forwards: [ForwardRule] = []) {
    self.servers = servers
    self.forwards = forwards
  }
}

public enum TunnelFrame: Equatable, Sendable {
  public static let subprotocol = "portside.tcp.v1"
  public static let maximumDataSize = 65536
  case data(Data)
  case eof

  public init(decoding bytes: Data) throws {
    guard bytes.count <= Self.maximumDataSize + 1, let tag = bytes.first else {
      throw PortsideError.invalid("The server sent an invalid tunnel frame.")
    }
    switch tag {
    case 0: self = .data(Data(bytes.dropFirst()))
    case 1 where bytes.count == 1: self = .eof
    default: throw PortsideError.invalid("The server sent an invalid tunnel frame.")
    }
  }

  public func encoded() throws -> Data {
    switch self {
    case .eof: return Data([1])
    case .data(let bytes):
      guard bytes.count <= Self.maximumDataSize else {
        throw PortsideError.invalid("TCP data chunk is too large.")
      }
      return Data([0]) + bytes
    }
  }
}
