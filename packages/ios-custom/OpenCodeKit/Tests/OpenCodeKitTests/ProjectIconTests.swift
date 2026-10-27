import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OpenCodeKit

private func project(_ icon: [String: String]?) throws -> Project {
  var value: [String: JSONValue] = ["id": .string("p"), "canonical": .string("/repo"), "sandboxes": .array([])]
  if let icon { value["icon"] = .object(icon.mapValues(JSONValue.string)) }
  return try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(JSONValue.object(value)))
}

private func png(_ side: Int) throws -> Data {
  let context = try #require(
    CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(CGColor(red: 0, green: 1, blue: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: side, height: side))
  let data = NSMutableData()
  let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
  #expect(CGImageDestinationFinalize(destination))
  return data as Data
}

private actor Renders {
  var count = 0
  func render(_ png: Data) -> Data {
    count += 1
    return png
  }
}

private let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1 1'><rect width='1' height='1'/></svg>"

@Test func projectIconFollowsTheWebSidebarAndAcceptsOnlySmallInlineImages() throws {
  let encoded = "data:image/svg+xml," + svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
  let base64 = "data:image/png;base64," + (try png(4)).base64EncodedString()
  #expect(ProjectIcon.of(try project(nil)) == nil)
  #expect(ProjectIcon.of(try project(["color": "pink"])) == nil)
  // The override wins over a discovered url and a color; a discovered url shows only without a color.
  #expect(ProjectIcon.of(try project(["override": encoded, "url": base64, "color": "pink"]))?.svg == true)
  #expect(ProjectIcon.of(try project(["url": base64]))?.svg == false)
  #expect(ProjectIcon.of(try project(["url": base64, "color": "pink"])) == nil)
  // Resolved once per source: the same value again, without decoding.
  #expect(ProjectIcon.of(try project(["url": base64])) == ProjectIcon(dataURL: base64))
  #expect(ProjectIcon(dataURL: encoded)?.data == Data(svg.utf8))
  #expect(ProjectIcon(dataURL: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString())?.data == Data(svg.utf8))
  // Same content, same cache key, whichever encoding; another icon gets another key.
  #expect(ProjectIcon(dataURL: encoded)?.key == ProjectIcon(dataURL: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString())?.key)
  #expect(ProjectIcon(dataURL: encoded)?.key != ProjectIcon(dataURL: base64)?.key)
  for rejected in [
    "https://example.com/icon.svg", "data:text/html,<svg/>", "data:image/png;base64,", "data:image/png;base64",
    "data:image/png;base64," + Data(count: ProjectIcon.maximumBytes + 1).base64EncodedString(),
  ] {
    #expect(ProjectIcon(dataURL: rejected) == nil)
  }
}

@Test func projectIconCacheRendersEachSVGRevisionOnceAndKeepsItOnDisk() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let raster = try png(ProjectIconCache.pixels)
  let renders = Renders()
  let render: @Sendable (Data, Int) async -> Data? = { _, _ in await renders.render(raster) }
  let first = try #require(ProjectIcon(dataURL: "data:image/svg+xml," + svg))
  let cache = ProjectIconCache(directory: directory)
  #expect(cache.cached(first) == nil)
  #expect(await cache.image(first, render: render)?.width == ProjectIconCache.pixels)
  #expect(cache.cached(first) != nil)
  #expect(await cache.image(first, render: render) != nil)
  #expect(await renders.count == 1)
  // A relaunch (a new cache over the same directory) reads the saved render.
  #expect(await ProjectIconCache(directory: directory).image(first, render: render) != nil)
  #expect(await renders.count == 1)
  // A new icon revision renders again; a raster icon never needs the renderer.
  let second = try #require(ProjectIcon(dataURL: "data:image/svg+xml," + svg.replacingOccurrences(of: "'1'/>", with: "'.5'/>")))
  #expect(await cache.image(second, render: render) != nil)
  #expect(await renders.count == 2)
  let png = try #require(ProjectIcon(dataURL: "data:image/png;base64," + raster.base64EncodedString()))
  #expect(await cache.image(png, render: render)?.width == ProjectIconCache.pixels)
  #expect(await renders.count == 2)
  // A failed render is not retried in the same process.
  let broken = try #require(ProjectIcon(dataURL: "data:image/svg+xml,<svg/>"))
  #expect(await cache.image(broken, render: { _, _ in nil }) == nil)
  #expect(await cache.image(broken, render: render) == nil)
  #expect(await renders.count == 2)
}
