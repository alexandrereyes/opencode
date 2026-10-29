import Foundation

/// Why a voice request for the screen captured nothing. The text is spoken back to GPT Live.
public enum VoiceScreenRefusal: Error, Equatable, Sendable, LocalizedError {
  /// Another app is in front, or the call runs in the background.
  case background
  /// The iPhone is locked.
  case locked
  /// This device or build cannot capture its window (for example the Mac app).
  case unavailable
  /// Rendering or encoding the window failed.
  case failed

  public var errorDescription: String? {
    let tail = " Nada foi enviado à Sessão mestra."
    return switch self {
    case .background:
      "Não consigo ver a tela: o OpenCode não está aberto na frente. Só vejo a tela do próprio OpenCode, nunca a de outros apps." + tail
    case .locked: "Não consigo ver a tela: o iPhone está bloqueado. Desbloqueie e abra o OpenCode." + tail
    case .unavailable: "Ver a tela só funciona no app OpenCode do iPhone." + tail
    case .failed: "Não consegui capturar a tela do OpenCode agora." + tail
    }
  }
}

public enum VoiceScreenAccess {
  /// Only the app's own window, while it is in front and unlocked; never another app.
  public static func refusal(appActive: Bool, protectedDataAvailable: Bool) -> VoiceScreenRefusal? {
    if !protectedDataAvailable { return .locked }
    if !appActive { return .background }
    return nil
  }
}

/// One JPEG of the OpenCode window taken when GPT Live asked for it, plus identifiers the image cannot show.
public struct VoiceScreenShot: Sendable, Equatable {
  public let jpeg: Data
  /// The conversation open in the app, so the master can read the real session.
  public let sessionID: String?
  public init(jpeg: Data, sessionID: String?) { self.jpeg = jpeg; self.sessionID = sessionID }

  public static let name = "tela-opencode.jpg"

  /// The delegated text plus one minimal line; the master reads the picture itself.
  public func prompt(_ text: String) -> String {
    let line = sessionID.map { "[Captura da tela do app OpenCode anexada. Sessão aberta no app: \($0)]" }
      ?? "[Captura da tela do app OpenCode anexada.]"
    return text + "\n\n" + line
  }
}
