#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
  ?? "/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-citacoes-prints")
for theme in ["dark", "light"] {
  for (kind, native) in [("pending", "full-pending-mark"), ("details", "full-pending-details"), ("sent", "sent-mark")] {
    let sources = ["web-\(kind)-\(theme).png", "native-\(native)-openchamber-\(theme).png"]
    let images = sources.map { NSImage(contentsOf: root.appendingPathComponent($0))! }
    let widths = images.map { $0.size.width * 1000 / $0.size.height }
    let size = NSSize(width: widths.reduce(12, +), height: 1036)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    (theme == "dark" ? NSColor.darkGray : .lightGray).setFill()
    NSRect(origin: .zero, size: size).fill()
    var x: CGFloat = 0
    for index in images.indices {
      images[index].draw(in: NSRect(x: x, y: 0, width: widths[index], height: 1000))
      (index == 0 ? "Custom web" : "Native iOS").draw(at: NSPoint(x: x + 8, y: 1009), withAttributes: [
        .font: NSFont.systemFont(ofSize: 14), .foregroundColor: theme == "dark" ? NSColor.white : .black,
      ])
      x += widths[index] + 12
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("comparison-\(kind)-\(theme).png"))
  }
}
