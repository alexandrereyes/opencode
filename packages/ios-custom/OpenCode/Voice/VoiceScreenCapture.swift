import Observation
import OpenCodeKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Hides the voice bar and toasts for the frame in which the voice screen capture renders the window.
@MainActor @Observable final class VoiceCaptureVeil {
  static let shared = VoiceCaptureVeil()
  private(set) var hidden = false
  func hide(_ value: Bool) { hidden = value }
}

extension View {
  /// Overlays that must not appear in the screen sent to the Sessão mestra.
  func voiceCaptureHidden() -> some View { modifier(VoiceCaptureHidden()) }
}

private struct VoiceCaptureHidden: ViewModifier {
  func body(content: Content) -> some View {
    // Opacity, not removal: the layout behind must not move in the capture.
    content.opacity(VoiceCaptureVeil.shared.hidden ? 0 : 1)
  }
}

/// Renders only OpenCode's own foreground window; never ReplayKit, the screen or the photo library.
@MainActor enum VoiceScreenCapture {
  static func capture(sessionID: String?) async throws(VoiceScreenRefusal) -> VoiceScreenShot {
    #if os(iOS)
    let application = UIApplication.shared
    if let refusal = VoiceScreenAccess.refusal(appActive: application.applicationState == .active,
      protectedDataAvailable: application.isProtectedDataAvailable) { throw refusal }
    guard let window = application.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive && $0.session.role == .windowApplication })?
      .keyWindow else { throw .background }
    return VoiceScreenShot(jpeg: try await render(window), sessionID: sessionID)
    #else
    throw .unavailable
    #endif
  }

  #if os(iOS)
  static func render(_ window: UIWindow) async throws(VoiceScreenRefusal) -> Data {
    let veil = VoiceCaptureVeil.shared
    veil.hide(true)
    defer { veil.hide(false) }
    // Let SwiftUI commit the hidden overlays before the window is drawn.
    try? await Task.sleep(for: .milliseconds(80))
    // Re-check after the wait: the app may have left the foreground meanwhile.
    guard UIApplication.shared.applicationState == .active else { throw .background }
    let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
    format.scale = min(window.screen.scale, 2)
    format.opaque = true
    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    guard let jpeg = image.jpegData(compressionQuality: 0.72) else { throw .failed }
    return jpeg
  }
  #endif
}
