import AppKit
import Foundation

@MainActor
public enum ClipboardFiles {
  public static func read(from pasteboard: NSPasteboard = .general) throws -> [FileUploadSource] {
    let urls =
      pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL] ?? []
    if !urls.isEmpty { return urls.map(FileUploadSource.file) }
    if let png = pasteboard.data(forType: .png) { return [.image(name: imageName(), data: png)] }
    if let image = NSImage(pasteboard: pasteboard) { return [try source(from: image)] }
    throw PortsideError.invalid("Copy an image or file first, then paste it here.")
  }

  public static func source(from image: NSImage) throws -> FileUploadSource {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else {
      throw PortsideError.invalid("This clipboard image could not be converted to PNG.")
    }
    return .image(name: imageName(), data: png)
  }

  private static func imageName() -> String {
    "clipboard-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).png"
  }
}
