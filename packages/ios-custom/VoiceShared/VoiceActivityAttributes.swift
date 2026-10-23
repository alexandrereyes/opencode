import ActivityKit
import AppIntents
import OpenCodeKit
import SwiftUI

struct VoiceActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var label: String
    var muted: Bool
    var working: Bool
    var speaking: Bool
    var colors: [String: [Double]]
    func color(_ role: ThemeRole) -> Color {
      let value = colors[String(role.rawValue)] ?? [0, 0, 0, 1]
      return Color(.sRGB, red: value[0], green: value[1], blue: value[2], opacity: value[3])
    }
  }
  let sessionID: String
  let started: Date
}

enum VoiceActivityAction: Sendable { case mute, end }

@MainActor enum VoiceActivityRouter {
  static var sessionID: String?
  static var handler: ((VoiceActivityAction) async -> Void)?
  static func perform(_ action: VoiceActivityAction, sessionID: String) async {
    guard self.sessionID == sessionID else { return }
    await handler?(action)
  }
}

struct VoiceMuteIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Silenciar ou reativar microfone"
  @Parameter(title: "Chamada") var sessionID: String
  init() {}
  init(sessionID: String) { self.sessionID = sessionID }
  func perform() async throws -> some IntentResult {
    await VoiceActivityRouter.perform(.mute, sessionID: sessionID)
    return .result()
  }
}

struct VoiceEndIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Encerrar conversa por voz"
  @Parameter(title: "Chamada") var sessionID: String
  init() {}
  init(sessionID: String) { self.sessionID = sessionID }
  func perform() async throws -> some IntentResult {
    await VoiceActivityRouter.perform(.end, sessionID: sessionID)
    return .result()
  }
}
