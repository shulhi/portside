import Foundation

public struct ConfigurationStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL? = nil) {
    self.fileURL =
      fileURL
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Portside", isDirectory: true).appendingPathComponent(
        "configuration.json")
  }

  public func load() throws -> ClientConfiguration {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return ClientConfiguration() }
    return try JSONDecoder().decode(ClientConfiguration.self, from: Data(contentsOf: fileURL))
  }

  public func save(_ configuration: ClientConfiguration) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(configuration).write(to: fileURL, options: [.atomic])
  }
}
