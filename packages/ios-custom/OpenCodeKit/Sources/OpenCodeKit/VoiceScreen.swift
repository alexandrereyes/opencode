import CoreGraphics
import Foundation

/// What to look at: the window in front, or the whole screen when Alexandre says "a tela toda" (`VoiceScreenIntent`);
/// `"screen": true | "front" | "app" | "display"` and `"screen_app": "Simulator"` in the JSON form the route never
/// sends. The iPhone always captures its own OpenCode window, whatever the target.
public enum VoiceScreenTarget: Sendable, Equatable {
  /// The window in front ("olha essa página").
  case front
  /// The front window of an app by name ("olha o simulador").
  case app(String)
  /// The whole screen with the window in front ("olha minha tela toda").
  case display

  /// Nil when the delegation does not ask for the screen. A named app wins over the screen value.
  public init?(screen: JSONValue?, app: JSONValue?) {
    if let name = app?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, screen?.bool != false {
      self = .app(name)
      return
    }
    if screen?.bool == true { self = .front; return }
    switch screen?.string?.lowercased() {
    case "display", "tela", "screen", "full", "tela inteira": self = .display
    case "front", "janela", "window", "app": self = .front
    default: return nil
    }
  }
}

/// Why a voice request for the screen captured nothing. The text is spoken back to GPT Live.
public enum VoiceScreenRefusal: Error, Equatable, Sendable, LocalizedError {
  /// Another app is in front, or the call runs in the background (iPhone).
  case background
  /// The iPhone is locked.
  case locked
  /// The app is behind its Face ID lock (Você ▸ Segurança): what it shows is not his to send.
  case appLocked
  /// This device or build cannot capture.
  case unavailable
  /// Rendering or encoding failed.
  case failed
  /// The named app is not open on the Mac.
  case appNotRunning(String)
  /// No visible window to look at (of the named app, when there is one).
  case noWindow(String?)
  /// The system keeps this window out of captures.
  case protected(String)
  /// Another app was asked without Screen Recording permission, and no OpenCode window could stand in.
  case permission

  public var errorDescription: String? {
    let tail = " Nada foi enviado à Sessão mestra."
    return switch self {
    case .background:
      "Não consigo ver a tela: o MyAgents não está aberto na frente. Só vejo a tela do próprio MyAgents, nunca a de outros apps." + tail
    case .locked: "Não consigo ver a tela: o iPhone está bloqueado. Desbloqueie e abra o MyAgents." + tail
    case .appLocked: "Não consigo ver a tela: o MyAgents está bloqueado pelo Face ID. Desbloqueie o app e peça de novo." + tail
    case .unavailable: "Ver a tela não funciona neste aparelho." + tail
    case .failed: "Não consegui capturar a tela agora." + tail
    case .appNotRunning(let name): "Não encontrei o app “\(name)” aberto neste Mac." + tail
    case .noWindow(let name):
      (name.map { "“\($0)” não tem nenhuma janela visível para eu ver." } ?? "Não há nenhuma janela na frente para eu ver.") + tail
    case .protected(let name): "O macOS não deixa capturar a janela de “\(name)”." + tail
    case .permission:
      "Para ver outros apps, o MyAgents precisa da permissão de Gravação de Tela em Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela."
        + tail
    }
  }
}

/// Whether Alexandre named the screen itself ("tá vendo minha tela?", "manda um print"), which is how the app knows to
/// attach the capture: on this route GPT Live never sends the `"screen"` field (the delegation's text is the transcript
/// of his turn, 02/11). Speech since the previous delegation counts too: "Pergunta pra Mestra" right after "tá vendo
/// minha tela?" is about the screen.
///
/// Only a narrow net. Phrases that point at something without naming the screen ("isso aqui", "olha aqui", "vê o que
/// cê acha", "o que acha disso") are everyday speech, and listing them here guessed wrong (31/10: "dá uma pesquisada…
/// vê o que cê acha" tried a capture). GPT Live delegates them anyway (02/11, 3 of 3, even when told to ask whether
/// to look), so they reach the master without a capture, and the app's screen block has GPT Live tell him he can
/// say "olha minha tela" when the result shows nothing was seen. An app by name ("olha o simulador") is not
/// recognized either: no phrase reliably names one.
public enum VoiceScreenIntent {
  private static let patterns = [
    #"\btelas?\b"#, #"\bscreenshots?\b"#, #"\bprints?\b"#, #"\bcaptura de tela\b"#,
  ].map { try! NSRegularExpression(pattern: $0) }
  private static let whole = try! NSRegularExpression(pattern: #"\btela (toda|inteira)\b"#)

  /// What his words ask to capture: the window in front, or the whole screen for "a tela toda" or "a tela inteira"
  /// (the Mac; the iPhone always captures its own window); nil when they do not name the screen.
  public static func target(_ text: String) -> VoiceScreenTarget? {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let range = NSRange(folded.startIndex..., in: folded)
    guard patterns.contains(where: { $0.firstMatch(in: folded, range: range) != nil }) else { return nil }
    return whole.firstMatch(in: folded, range: range) == nil ? .front : .display
  }
}

public enum VoiceScreenAccess {
  /// Only the app's own window, while it is in front and unlocked; never another app.
  public static func refusal(appActive: Bool, protectedDataAvailable: Bool, appLocked: Bool = false)
    -> VoiceScreenRefusal?
  {
    if !protectedDataAvailable { return .locked }
    if !appActive { return .background }
    if appLocked { return .appLocked }
    return nil
  }
}

/// One JPEG taken when GPT Live asked for it, plus identifiers the image cannot show.
public struct VoiceScreenShot: Sendable, Equatable {
  public let jpeg: Data
  /// The conversation open in OpenCode, when the capture is OpenCode's window.
  public let sessionID: String?
  /// What was captured, as in "da janela de Google Chrome (“Docs”)"; nil means the iPhone's OpenCode screen.
  public let subject: String?
  /// Spoken to GPT Live after the master gets the picture, for example a missing permission.
  public let notice: String?
  public init(jpeg: Data, sessionID: String?, subject: String? = nil, notice: String? = nil) {
    self.jpeg = jpeg; self.sessionID = sessionID; self.subject = subject; self.notice = notice
  }

  public static let name = "tela-opencode.jpg"

  /// The delegated text plus one minimal line; the master reads the picture itself.
  public func prompt(_ text: String) -> String {
    let session = sessionID.map { " Sessão aberta no app: \($0)" } ?? ""
    return text + "\n\n[Captura " + (subject ?? "da tela do app MyAgents") + " anexada." + session + "]"
  }
}

/// A window as the Mac's window server lists it, front to back.
public struct VoiceScreenWindow: Sendable, Equatable {
  public let id: UInt32
  public let pid: Int32
  public let app: String
  public let title: String?
  public let frame: CGRect
  /// 0 for ordinary windows; menus, the Dock and panels sit on higher layers.
  public let layer: Int
  public init(id: UInt32, pid: Int32, app: String, title: String? = nil, frame: CGRect, layer: Int = 0) {
    self.id = id; self.pid = pid; self.app = app; self.title = title; self.frame = frame; self.layer = layer
  }
}

/// What the Mac captures for a target.
public enum VoiceScreenSource: Sendable, Equatable {
  /// OpenCode's own window, which needs no permission.
  case own
  case window(VoiceScreenWindow)
  /// A display; OpenCode's windows appear only when OpenCode is the app in front.
  case display(id: UInt32, includesOwn: Bool, front: String?)
}

public struct VoiceScreenPlan: Sendable, Equatable {
  public let source: VoiceScreenSource
  /// Said to GPT Live after sending, when OpenCode's window stands in for another app.
  public let notice: String?
  /// Ask macOS for Screen Recording now: the first time another app was wanted without it.
  public let requestsPermission: Bool
}

/// Chooses what to capture on the Mac. Pure, so the rules are testable without windows or permission.
public enum VoiceScreenPlanner {
  public struct App: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public init(pid: Int32, name: String) { self.pid = pid; self.name = name }
  }
  public struct Display: Sendable, Equatable {
    public let id: UInt32
    public let frame: CGRect
    public init(id: UInt32, frame: CGRect) { self.id = id; self.frame = frame }
  }

  public static let firstRequestNotice = """
    Pedi ao macOS a permissão de Gravação de Tela. Até ela ser liberada em Ajustes do Sistema → Privacidade e \
    Segurança → Gravação de Tela, com o MyAgents reaberto, só vejo a janela do MyAgents; enviei essa janela à mestra.
    """
  public static let deniedNotice = """
    Sem a permissão de Gravação de Tela só vejo a janela do MyAgents; enviei essa janela à mestra. Para ver outros \
    apps, libere o MyAgents em Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela.
    """

  /// OpenCode counts as the screen only when it is the app in front; a call shown by OpenCode in the background
  /// never covers the app Alexandre is looking at.
  public static func plan(_ target: VoiceScreenTarget, own: Int32, front: Int32?, apps: [App],
    windows: [VoiceScreenWindow], displays: [Display], permission: Bool, asked: Bool, ownWindow: Bool)
    throws(VoiceScreenRefusal) -> VoiceScreenPlan {
    let source = try wanted(target, own: own, front: front, apps: apps, windows: windows, displays: displays)
    if source == .own || permission { return VoiceScreenPlan(source: source, notice: nil, requestsPermission: false) }
    guard ownWindow else { throw .permission }
    return VoiceScreenPlan(source: .own, notice: asked ? deniedNotice : firstRequestNotice, requestsPermission: !asked)
  }

  private static func wanted(_ target: VoiceScreenTarget, own: Int32, front: Int32?, apps: [App],
    windows: [VoiceScreenWindow], displays: [Display]) throws(VoiceScreenRefusal) -> VoiceScreenSource {
    let ordinary = windows.filter { $0.layer == 0 && $0.frame.width > 40 && $0.frame.height > 40 }
    switch target {
    case .front:
      if front == own { return .own }
      if let window = ordinary.first(where: { $0.pid == front }) ?? ordinary.first(where: { $0.pid != own }) {
        return .window(window)
      }
      throw .noWindow(nil)
    case .app(let name):
      guard let app = match(name, in: apps) else { throw .appNotRunning(name) }
      if app.pid == own { return .own }
      guard let window = ordinary.first(where: { $0.pid == app.pid }) else { throw .noWindow(app.name) }
      return .window(window)
    case .display:
      let anchor = ordinary.first(where: { $0.pid == front })
      let display = anchor.flatMap { window in
        displays.first { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }
      } ?? displays.first
      guard let display else { throw .unavailable }
      return .display(id: display.id, includesOwn: front == own, front: apps.first { $0.pid == front }?.name)
    }
  }

  /// Exact name first, then a name that starts with or contains it ("chrome" → "Google Chrome"), ignoring case and accents.
  public static func match(_ name: String, in apps: [App]) -> App? {
    func fold(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    let wanted = fold(name)
    return apps.first { fold($0.name) == wanted } ?? apps.first { fold($0.name).hasPrefix(wanted) }
      ?? apps.first { fold($0.name).contains(wanted) }
  }

  /// The line's subject for the master: identifiers only, never a description.
  public static func subject(_ source: VoiceScreenSource) -> String {
    switch source {
    case .own: "da janela do MyAgents"
    case .window(let window):
      "da janela de \(window.app)" + (window.title.flatMap { $0.isEmpty ? nil : " (“\($0.prefix(120))”)" } ?? "")
    case .display(_, _, let front): "da tela inteira do Mac" + (front.map { " (\($0) na frente)" } ?? "")
    }
  }
}
