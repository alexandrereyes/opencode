// Crops and side-by-side comparisons for the Mac app's captures, without third-party tools.
//
//   swift packages/ios-custom/script/mac-prints.swift crop <in.png> <out.png> <x> <y> <width> <height>
//     (fractions of the image, top-left origin)
//   swift packages/ios-custom/script/mac-prints.swift compare <out.png> <mock.png> <app.png> [<mock.png> <app.png> …]
//     (one row per pair, the approved mock on the left, each scaled to the same height)
import AppKit

func load(_ path: String) -> CGImage {
  guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Não foi possível ler \(path)")
  }
  return image
}

func save(_ image: CGImage, _ path: String) {
  guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("PNG") }
  try! png.write(to: URL(fileURLWithPath: path))
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "crop":
  let values = Array(arguments.dropFirst())
  let image = load(values[0])
  let fractions = values[2...5].map { Double($0)! }
  let width = Double(image.width)
  let height = Double(image.height)
  let rect = CGRect(x: fractions[0] * width, y: fractions[1] * height, width: fractions[2] * width, height: fractions[3] * height)
  save(image.cropping(to: rect.integral)!, values[1])
case "compare":
  let values = Array(arguments.dropFirst())
  let output = values[0]
  let pairs = stride(from: 1, to: values.count - 1, by: 2).map { (load(values[$0]), load(values[$0 + 1])) }
  let rowHeight = 1400.0
  let gap = 40.0
  let scaled = pairs.map { pair in
    [pair.0, pair.1].map { image in (image, Double(image.width) * rowHeight / Double(image.height)) }
  }
  let width = scaled.map { $0.reduce(gap) { $0 + $1.1 + gap } }.max() ?? 0
  let height = Double(pairs.count) * (rowHeight + gap) + gap
  let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(gray: 0.04, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  for (row, images) in scaled.enumerated() {
    var x = gap
    let y = height - Double(row + 1) * (rowHeight + gap)
    for (image, imageWidth) in images {
      context.draw(image, in: CGRect(x: x, y: y, width: imageWidth, height: rowHeight))
      x += imageWidth + gap
    }
  }
  save(context.makeImage()!, output)
default:
  print("Uso: mac-prints.swift crop|compare …")
}
