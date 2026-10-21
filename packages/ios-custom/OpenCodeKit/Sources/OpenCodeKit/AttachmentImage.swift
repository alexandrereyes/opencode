import Foundation
import ImageIO
import zlib

public enum AttachmentImage {
  public static func thumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
    guard maxPixelSize > 0, validPNG(data),
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetStatus(source) == .statusComplete
    else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      ] as CFDictionary)
  }

  // ImageIO can return a metadata-backed image for a corrupt PNG and fail only
  // when painting it. Validate the chunk checksums without inflating its bitmap.
  private static func validPNG(_ data: Data) -> Bool {
    guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return true }
    return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      var offset = 8
      func number(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
      }
      while offset + 12 <= bytes.count {
        let length = Int(number(offset))
        guard length <= bytes.count - offset - 12, length <= Int(UInt32.max) - 4 else {
          return false
        }
        let expected = number(offset + 8 + length)
        let actual = crc32(
          0, bytes.bindMemory(to: Bytef.self).baseAddress?.advanced(by: offset + 4),
          uInt(length + 4))
        guard actual == expected else { return false }
        let end = number(offset + 4) == 0x4945_4e44
        offset += length + 12
        if end { return length == 0 && offset == bytes.count }
      }
      return false
    }
  }
}
