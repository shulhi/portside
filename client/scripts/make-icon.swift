import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = points * scale
    let size = CGFloat(pixels)
    let image = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    let inset = size * 0.075
    let square = NSBezierPath(
      roundedRect: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2),
      xRadius: size * 0.19, yRadius: size * 0.19)
    NSGradient(
      starting: NSColor(srgbRed: 0.15, green: 0.58, blue: 0.48, alpha: 1),
      ending: NSColor(srgbRed: 0.06, green: 0.34, blue: 0.29, alpha: 1))!.draw(
        in: square, angle: -70)
    let arrow = NSBezierPath()
    arrow.lineWidth = size * 0.066
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: size * 0.32, y: size * 0.32))
    arrow.line(to: NSPoint(x: size * 0.68, y: size * 0.68))
    arrow.move(to: NSPoint(x: size * 0.39, y: size * 0.68))
    arrow.line(to: NSPoint(x: size * 0.68, y: size * 0.68))
    arrow.line(to: NSPoint(x: size * 0.68, y: size * 0.39))
    NSColor.white.setStroke()
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try image.representation(using: .png, properties: [:])!.write(
      to: directory.appendingPathComponent(filename))
  }
}
