#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Rebuild from the chosen source art, with no external dependencies. UIKit masks the corners.
struct Theme: Decodable {
  let colors: [String: String]
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("OpenCode/Assets.xcassets")
let theme = try JSONDecoder().decode(
  Theme.self,
  from: Data(contentsOf: root.appendingPathComponent("OpenCode/Resources/Themes/openchamber-dark.json")))

func components(_ role: String) -> [CGFloat] {
  let hex = theme.colors[role]!.dropFirst()
  let value = UInt32(hex, radix: 16)!
  return [16, 8, 0].map { CGFloat((value >> $0) & 255) / 255 }
}

func write(_ data: Data, to url: URL) throws {
  if (try? Data(contentsOf: url)) == data { return }
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: url, options: .atomic)
}

func writeJSON(_ value: [String: Any], to path: String) throws {
  var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  data.append(10)
  try write(data, to: assets.appendingPathComponent(path))
}

let source = CGImageSourceCreateWithURL(root.appendingPathComponent("script/icon-source.png") as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
precondition(image.width == image.height, "The source icon must be square")
// No alpha channel: App Store Connect rejects transparent marketing icons.
let context = CGContext(
  data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: components("background") + [1])!)
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let data = NSMutableData()
let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination), "Could not encode the app icon")
try write(data as Data, to: assets.appendingPathComponent("AppIcon.appiconset/AppIcon.png"))

let info: [String: Any] = ["author": "xcode", "version": 1]
try writeJSON(["info": info], to: "Contents.json")
try writeJSON([
  "info": info,
  "images": [
    ["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
  ],
], to: "AppIcon.appiconset/Contents.json")
let background = components("background")
try writeJSON([
  "info": info,
  "colors": [["idiom": "universal", "color": ["color-space": "srgb", "components": [
    "red": String(format: "%.8f", Double(background[0])),
    "green": String(format: "%.8f", Double(background[1])),
    "blue": String(format: "%.8f", Double(background[2])), "alpha": "1.00000000",
  ]]]],
], to: "LaunchBackground.colorset/Contents.json")
// The Apple Watch app uses the same opaque 1024-point image; watchOS applies its circular mask.
let watchAssets = root.appendingPathComponent("OpenCodeWatch/Assets.xcassets")
try write(data as Data, to: watchAssets.appendingPathComponent("AppIcon.appiconset/AppIcon.png"))
for (path, value) in [
  ("Contents.json", ["info": info] as [String: Any]),
  ("AppIcon.appiconset/Contents.json", ["info": info, "images": [
    ["filename": "AppIcon.png", "idiom": "universal", "platform": "watchos", "size": "1024x1024"],
  ]] as [String: Any]),
] {
  var json = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  json.append(10)
  try write(json, to: watchAssets.appendingPathComponent(path))
}
print("AppIcon rebuilt from script/icon-source.png (iPhone and Apple Watch); launch color from OpenChamber dark.")
