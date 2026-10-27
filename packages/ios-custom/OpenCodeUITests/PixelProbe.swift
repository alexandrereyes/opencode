import XCTest

extension XCUIElement {
  /// On-screen pixels close to `hex` (a color an icon clearly shows), optionally only in the leading `leading` points.
  func pixels(near hex: String, leading: CGFloat? = nil) -> Int {
    guard let full = screenshot().image.cgImage, let value = UInt32(hex, radix: 16) else { return 0 }
    let scale = CGFloat(full.width) / max(frame.width, 1)
    guard
      let image = leading.map({ full.cropping(to: CGRect(x: 0, y: 0, width: $0 * scale, height: CGFloat(full.height))) })
        ?? full
    else { return 0 }
    let target = [Int(value >> 16 & 255), Int(value >> 8 & 255), Int(value & 255)]
    var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard
      let context = CGContext(
        data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return stride(from: 0, to: buffer.count, by: 4).filter { index in
      (0..<3).allSatisfy { abs(Int(buffer[index + $0]) - target[$0]) <= 24 }
    }.count
  }
}
