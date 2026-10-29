import Foundation

public enum ServerAPI {
  public static func info(for profile: ServerProfile, token: String) async throws -> ServerInfo {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 10
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: try profile.url(path: "/v1/info"))
    request.setValue(
      "Bearer \(try TokenVault.validate(token))", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw PortsideError.disconnected }
    guard response.statusCode == 200 else { throw PortsideError.http(response.statusCode) }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let info = try decoder.decode(ServerInfo.self, from: data)
    guard info.protocol == TunnelFrame.subprotocol, info.maxDataSize == TunnelFrame.maximumDataSize
    else {
      throw PortsideError.protocolMismatch
    }
    return info
  }
}
