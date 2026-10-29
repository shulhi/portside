import AppKit
import Foundation
import XCTest

@testable import PortsideCore

@MainActor
final class ClipboardTests: XCTestCase {
  func testPNGClipboardPreservesOriginalBytes() throws {
    let board = NSPasteboard(name: .init("app.portside.test.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let bytes = try pngImage()
    board.setData(bytes, forType: .png)
    let items = try ClipboardFiles.read(from: board)
    XCTAssertEqual(items.count, 1)
    guard case .image(let name, let uploaded) = items[0] else {
      return XCTFail("Expected a clipboard image")
    }
    XCTAssertTrue(name.hasSuffix(".png"))
    XCTAssertEqual(uploaded, bytes)
  }

  func testTIFFClipboardConvertsToPNG() throws {
    let board = NSPasteboard(name: .init("app.portside.test.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let image = NSImage(data: try pngImage())!
    board.setData(image.tiffRepresentation!, forType: .tiff)
    let items = try ClipboardFiles.read(from: board)
    guard case .image(_, let uploaded) = items[0] else { return XCTFail("Expected converted PNG") }
    XCTAssertEqual(Array(uploaded.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    XCTAssertNotNil(NSImage(data: uploaded))
  }

  func testCopiedFilesTakePrecedenceOverAnImageRepresentation() throws {
    let board = NSPasteboard(name: .init("app.portside.test.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo test.png")
    board.writeObjects([url as NSURL])
    board.setData(try pngImage(), forType: .png)
    let items = try ClipboardFiles.read(from: board)
    XCTAssertEqual(items.count, 1)
    guard case .file(let file) = items[0] else { return XCTFail("Expected a file URL") }
    XCTAssertEqual(file, url)
  }

  func testEmptyClipboardProducesAnActionableError() {
    let board = NSPasteboard(name: .init("app.portside.test.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    XCTAssertThrowsError(try ClipboardFiles.read(from: board))
  }

  private func pngImage() throws -> Data {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.setColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), atX: 0, y: 0)
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }
}
