import Foundation

public struct UploadSettings: Decodable, Sendable {
  public let directory: String
  public let maxFileSize: Int64
}

public struct UploadedFile: Decodable, Equatable, Sendable {
  public let name: String
  public let path: String
  public let bytes: Int64
}

public enum UploadDestination {
  public static func validateFolder(_ folder: String) throws {
    guard folder.utf8.count <= 1024, !folder.contains("\\"),
      !folder.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      folder.isEmpty
        || folder.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
          !$0.isEmpty && $0 != "." && $0 != ".."
        })
    else {
      throw PortsideError.invalid(
        "Use a relative subfolder such as project/screenshots, without / at the start or dot segments."
      )
    }
  }

  public static func displayPath(root: String, folder: String) -> String {
    folder.isEmpty ? root : root + "/" + folder
  }
}

public enum FileUploadSource: Sendable {
  case file(URL)
  case image(name: String, data: Data)

  public var name: String {
    switch self {
    case .file(let url): url.lastPathComponent
    case .image(let name, _): name
    }
  }
}

public enum FileUploadAPI {
  public static func upload(
    _ source: FileUploadSource, to server: ServerProfile,
    settings: UploadSettings, progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> UploadedFile {
    try server.validate()
    var components = URLComponents(
      url: try server.url(path: "/v1/files"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "filename", value: source.name),
      URLQueryItem(name: "folder", value: server.uploadFolder),
    ]
    guard let url = components.url else {
      throw PortsideError.invalid("Cannot build the upload destination.")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 600
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let delegate = UploadDelegate(progress: progress)
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    let responseData: Data
    let response: URLResponse
    switch source {
    case .file(let fileURL):
      let access = fileURL.startAccessingSecurityScopedResource()
      defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
      let metadata = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard metadata.isRegularFile == true else {
        throw PortsideError.invalid("Drop regular files. Folders must be zipped first.")
      }
      guard let size = metadata.fileSize, Int64(size) <= settings.maxFileSize else {
        throw tooLarge()
      }
      (responseData, response) = try await session.upload(for: request, fromFile: fileURL)
    case .image(_, let data):
      guard data.count <= settings.maxFileSize else { throw tooLarge() }
      (responseData, response) = try await session.upload(for: request, from: data)
    }
    guard let response = response as? HTTPURLResponse else { throw PortsideError.disconnected }
    guard response.statusCode == 201 else {
      if let body = try? JSONDecoder().decode(UploadError.self, from: responseData) {
        throw PortsideError.invalid(body.error.message)
      }
      if response.statusCode == 404 {
        throw PortsideError.invalid(
          "Update the server and configure --upload-dir to enable file uploads.")
      }
      throw PortsideError.http(response.statusCode)
    }
    return try JSONDecoder().decode(UploadedFile.self, from: responseData)
  }

  private static func tooLarge() -> PortsideError {
    .invalid("This file exceeds the server's upload size limit.")
  }
  private struct UploadError: Decodable {
    let error: Detail
    struct Detail: Decodable { let message: String }
  }
}

private final class UploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let progress: @Sendable (Double) -> Void
  init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) {
    guard totalBytesExpectedToSend > 0 else { return }
    progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
