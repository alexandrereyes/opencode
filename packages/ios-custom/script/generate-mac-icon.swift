#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The Mac app's icon from the iPhone's source art (`script/icon-source.png`): the macOS grid (an 824-point rounded
// rectangle centered in 1024 with a soft shadow) at every size of `OpenCodeMac/MacAssets.xcassets/MacAppIcon`.
// macOS, unlike iOS, does not mask a square icon, so the corners are drawn here.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let folder = root.appendingPathComponent("OpenCodeMac/MacAssets.xcassets/MacAppIcon.appiconset")
let source = CGImageSourceCreateWithURL(root.appendingPathComponent("script/icon-source.png") as CFURL, nil)!
let art = CGImageSourceCreateImageAtIndex(source, 0, nil)!

func render(_ pixels: Int) -> Data {
  let scale = CGFloat(pixels) / 1024
  let context = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.interpolationQuality = .high
  let rect = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
  let shape = CGPath(roundedRect: rect, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
    color: CGColor(gray: 0, alpha: 0.35))
  context.addPath(shape)
  context.setFillColor(CGColor(gray: 0, alpha: 1))
  context.fillPath()
  context.restoreGState()
  context.addPath(shape)
  context.clip()
  context.draw(art, in: rect)
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  return data as Data
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
  for factor in [1, 2] {
    let name = "icon_\(size)x\(size)\(factor == 2 ? "@2x" : "").png"
    try render(size * factor).write(to: folder.appendingPathComponent(name), options: .atomic)
    images.append(["filename": name, "idiom": "mac", "scale": "\(factor)x", "size": "\(size)x\(size)"])
  }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
var json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
json.append(10)
try json.write(to: folder.appendingPathComponent("Contents.json"), options: .atomic)
let catalog = ["info": ["author": "xcode", "version": 1]]
var top = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
top.append(10)
try top.write(to: folder.deletingLastPathComponent().appendingPathComponent("Contents.json"), options: .atomic)
print("MacAppIcon: \(images.count) images")
