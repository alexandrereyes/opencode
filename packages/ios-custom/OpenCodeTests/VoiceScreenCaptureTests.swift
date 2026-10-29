import SwiftUI
import UIKit
import XCTest
@testable import OpenCode
@testable import OpenCodeKit

@MainActor final class VoiceScreenCaptureTests: XCTestCase {
  /// The real veil and renderer: the voice bar and toasts vanish from the capture, the window behind stays.
  func testCaptureHidesTheVoiceBarAndToastsButKeepsTheScreen() async throws {
    let toast = ToastCenter()
    toast.show("Banner que não pode aparecer")
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
    window.windowLevel = .alert + 1
    window.rootViewController = UIHostingController(rootView:
      ZStack {
        Color(red: 0, green: 1, blue: 0)
        VStack(spacing: 0) {
          Color(red: 0, green: 0, blue: 1).frame(height: 100)
          Spacer()
          Color(red: 1, green: 0, blue: 0).frame(height: 100).voiceCaptureHidden()
        }
      }.ignoresSafeArea().toastOverlay(toast))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(300))
    let jpeg = try await VoiceScreenCapture.render(window)
    XCTAssertFalse(VoiceCaptureVeil.shared.hidden, "the bar comes back right after the capture")
    let image = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
    XCTAssertLessThanOrEqual(image.width, 600, "rendered at most at 2x")
    let attachment = XCTAttachment(data: jpeg, uniformTypeIdentifier: "public.jpeg")
    attachment.name = "voice-screen-capture-hosted"; attachment.lifetime = .keepAlways; add(attachment)
    let top = try pixel(image, x: 0.5, y: 50 / 600)
    XCTAssertGreaterThan(top.blue, 200, "the screen itself is captured")
    let bar = try pixel(image, x: 0.5, y: 550 / 600)
    XCTAssertGreaterThan(bar.green, 200, "the voice bar is hidden, not drawn")
    XCTAssertLessThan(bar.red, 60)
    // The toast sits at the top over the blue band; with the veil the band is plain blue.
    for x in stride(from: 0.2, through: 0.8, by: 0.1) {
      let sample = try pixel(image, x: x, y: 40 / 600)
      XCTAssertGreaterThan(sample.blue, 200); XCTAssertLessThan(sample.red + sample.green, 80)
    }
  }

  private func pixel(_ image: CGImage, x: Double, y: Double) throws -> (red: Int, green: Int, blue: Int) {
    var data = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let px = Int(x * Double(image.width)), py = Int(y * Double(image.height))
    context.draw(image, in: CGRect(x: -px, y: -(image.height - 1 - py), width: image.width, height: image.height))
    return (Int(data[0]), Int(data[1]), Int(data[2]))
  }
}
