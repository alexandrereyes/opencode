import Foundation

public enum ImageZoomGeometry {
  public static func fit(image: CGSize, viewport: CGSize) -> CGFloat {
    guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
    return min(viewport.width / image.width, viewport.height / image.height)
  }

  public static func rect(at point: CGPoint, viewport: CGSize, scale: CGFloat) -> CGRect {
    let size = CGSize(width: viewport.width / scale, height: viewport.height / scale)
    return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
      width: size.width, height: size.height)
  }
}
