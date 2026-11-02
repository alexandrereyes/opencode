import ImageIO
import OpenCodeKit
import UIKit
import XCTest
@testable import OpenCode

/// A camera photo goes through the attachment pipeline upright: the EXIF orientation survives a small photo, and a
/// full-size one is converted to an upright JPEG within the pipeline's 2048 pixels, as a photo from Fotos is.
@MainActor final class ComposerCameraTests: XCTestCase {
  private func upright(_ data: Data) throws -> (Int, Int) {
    let image = try XCTUnwrap(AttachmentImage.thumbnail(data, maxPixelSize: nil))
    return (image.width, image.height)
  }
  private func sideways(width: Int, height: Int) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let base = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
      UIColor.systemTeal.setFill()
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return UIImage(cgImage: base.cgImage!, scale: 1, orientation: .right)
  }

  func testSmallPhotoKeepsItsOrientation() throws {
    let data = try XCTUnwrap(ComposerCamera.jpeg(sideways(width: 300, height: 200)))
    let (prepared, name, mime) = try AttachmentEncoding.prepare(data, name: "Foto-abc.jpg", mime: "image/jpeg")
    XCTAssertEqual(mime, "image/jpeg")
    XCTAssertTrue(name.hasPrefix("Foto-abc."), name)
    let (width, height) = try upright(prepared)
    XCTAssertEqual(width, 200)
    XCTAssertEqual(height, 300)
  }

  func testFullSizePhotoBecomesAnUprightJPEGWithinTheLimit() throws {
    let data = try XCTUnwrap(ComposerCamera.jpeg(sideways(width: 4032, height: 3024)))
    let (prepared, name, mime) = try AttachmentEncoding.prepare(data, name: "Foto-abc.jpg", mime: "image/jpeg")
    XCTAssertEqual(mime, "image/jpeg")
    XCTAssertEqual(name, "Foto-abc.jpg")
    let (width, height) = try upright(prepared)
    XCTAssertEqual(width, 1536)
    XCTAssertEqual(height, 2048)
    XCTAssertLessThan(prepared.count, AttachmentEncoding.draftLimit)
  }

  func testCameraUsageDescriptionCoversPhotosAndPairing() throws {
    let text = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String)
    XCTAssertTrue(text.contains("fotos"))
    XCTAssertTrue(text.contains("QR code"))
  }
}
