import SwiftUI

private struct VoiceContextKey: EnvironmentKey { static let defaultValue: VoiceController? = nil }
private struct VoiceSessionStoreKey: EnvironmentKey { static let defaultValue: SessionStore? = nil }
extension EnvironmentValues {
  var voiceController: VoiceController? {
    get { self[VoiceContextKey.self] }
    set { self[VoiceContextKey.self] = newValue }
  }
  var voiceSessionStore: SessionStore? {
    get { self[VoiceSessionStoreKey.self] }
    set { self[VoiceSessionStoreKey.self] = newValue }
  }
}
