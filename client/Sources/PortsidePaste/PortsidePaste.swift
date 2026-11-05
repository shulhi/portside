import AppKit
import Darwin
import Foundation
import ImageIO
import PortsideCore
import UniformTypeIdentifiers

@main
struct PortsidePaste {
  @MainActor
  static func main() {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let showProgress = arguments.first == "--progress"
    if showProgress { arguments.removeFirst() }
    if showProgress {
      let app = NSApplication.shared
      app.setActivationPolicy(.accessory)
      Task { @MainActor in exit(await run(arguments, showProgress: true)) }
      app.run()
    } else {
      Task { @MainActor in exit(await run(arguments, showProgress: false)) }
      dispatchMain()
    }
  }

  @MainActor
  private static func run(_ arguments: [String], showProgress: Bool) async -> Int32 {
    if arguments == ["--help"] {
      print("Usage: portside-paste [--host TAILSCALE_IP [--port PORT] [--folder SUBFOLDER]]")
      return EXIT_SUCCESS
    }
    do {
      var options: [String: String] = [:]
      var iterator = arguments.makeIterator()
      while let key = iterator.next() {
        guard ["--host", "--port", "--folder", "--pasteboard"].contains(key),
          options[key] == nil, let value = iterator.next()
        else { throw PortsideError.invalid("See portside-paste --help for usage.") }
        options[key] = value
      }
      let board = options["--pasteboard"].map { NSPasteboard(name: .init($0)) } ?? .general
      guard let image = try clipboardImage(board) else { return EXIT_SUCCESS }
      let name = "clipboard-\(UUID().uuidString.lowercased()).png"
      let path: String
      if let host = options["--host"] {
        guard isTailscaleIP(host), let port = UInt16(options["--port"] ?? "9417"), port > 0 else {
          throw PortsideError.invalid("Use a numeric Tailscale IP and a valid Portside port.")
        }
        let profile = ServerProfile(
          name: "Rex image paste", host: host, port: port, uploadFolder: options["--folder"] ?? "")
        let progress = showProgress ? PasteProgress() : nil
        defer { progress?.close() }
        guard let settings = try await ServerAPI.info(for: profile).uploads else {
          throw PortsideError.invalid("Enable file uploads on the Portside server first.")
        }
        path = try await FileUploadAPI.upload(
          .image(name: name, data: image), to: profile,
          settings: settings
        ) { fraction in
          Task { @MainActor in progress?.update(fraction) }
        }.path
      } else {
        guard options["--port"] == nil, options["--folder"] == nil else {
          throw PortsideError.invalid("--port and --folder require --host.")
        }
        let directory = try FileManager.default.url(
          for: .cachesDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true
        ).appendingPathComponent("Portside/RexImages", isDirectory: true)
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(name)
        try image.write(to: file, options: .atomic)
        path = file.path
      }
      guard path.hasPrefix("/"),
        !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw PortsideError.invalid("Portside returned an invalid image path.")
      }
      print(path)
      return EXIT_SUCCESS
    } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      return EXIT_FAILURE
    }
  }

  private static func isTailscaleIP(_ host: String) -> Bool {
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    if inet_pton(AF_INET, host, &ipv4) == 1 {
      return withUnsafeBytes(of: &ipv4) { $0[0] == 100 && (64...127).contains($0[1]) }
    }
    return inet_pton(AF_INET6, host, &ipv6) == 1
      && withUnsafeBytes(of: &ipv6) {
        Array($0.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
      }
  }

  @MainActor
  private static func clipboardImage(_ board: NSPasteboard) throws -> Data? {
    let urls =
      board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL] ?? []
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    let source: CGImageSource?
    if !urls.isEmpty {
      guard urls.count == 1, let url = urls.first,
        let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
        metadata.isRegularFile == true, metadata.contentType?.conforms(to: .image) == true
      else { return nil }
      source = CGImageSourceCreateWithURL(url as CFURL, options)
    } else {
      guard
        let type = board.types?.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }),
        let data = board.data(forType: type)
      else { return nil }
      source = CGImageSourceCreateWithData(data as CFData, options)
    }
    let thumbnailOptions =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 2000,
      ] as CFDictionary
    let output = NSMutableData()
    guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { throw PortsideError.invalid("Could not read the clipboard image.") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw PortsideError.invalid("Could not encode the clipboard image as PNG.")
    }
    return output as Data
  }
}
