import CoreGraphics
import Foundation

/// What GPT Live asked to look at: `"screen": true | "front" | "app" | "display"`, `"screen_app": "Simulator"`.
/// The iPhone always captures its own OpenCode window, whatever the target.
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
      "Não consigo ver a tela: o OpenCode não está aberto na frente. Só vejo a tela do próprio OpenCode, nunca a de outros apps." + tail
    case .locked: "Não consigo ver a tela: o iPhone está bloqueado. Desbloqueie e abra o OpenCode." + tail
    case .unavailable: "Ver a tela não funciona neste aparelho." + tail
    case .failed: "Não consegui capturar a tela agora." + tail
    case .appNotRunning(let name): "Não encontrei o app “\(name)” aberto neste Mac." + tail
    case .noWindow(let name):
      (name.map { "“\($0)” não tem nenhuma janela visível para eu ver." } ?? "Não há nenhuma janela na frente para eu ver.") + tail
    case .protected(let name): "O macOS não deixa capturar a janela de “\(name)”." + tail
    case .permission:
      "Para ver outros apps, o OpenCode precisa da permissão de Gravação de Tela em Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela."
        + tail
    }
  }
}

/// Whether Alexandre is talking about what is on screen, so a delegation GPT Live sent without `"screen"` still
/// carries the capture. Speech since the previous delegation counts too: "Pergunta pra Mestra" right after
/// "tá vendo minha tela?" is about the screen.
public enum VoiceScreenIntent {
  private static let patterns = [
    #"\btelas?\b"#, #"\bscreen(shot)?s?\b"#, #"\bprints?\b"#, #"\bcaptura(r)?\b"#, #"\bjanelas?\b"#,
    #"\bpaginas?\b"#, #"\bisso aqui\b"#, #"\bisto aqui\b"#, #"\bolha (aqui|isso|isto|so|essa|esse|ai|la)\b"#,
    #"\b(ve|ver|vendo|veja|vejo|enxerga|enxergando) (isso|isto|aqui|essa|esse|o que)\b"#,
    #"\bo que (voce |vc |ce )?acha diss[oa]\b"#, #"\bque erro e esse\b"#, #"\bo que (ta|esta) aparecendo\b"#,
  ].map { try! NSRegularExpression(pattern: $0) }

  public static func mentionsScreen(_ text: String) -> Bool {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
    let range = NSRange(folded.startIndex..., in: folded)
    return patterns.contains { $0.firstMatch(in: folded, range: range) != nil }
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
    return text + "\n\n[Captura " + (subject ?? "da tela do app OpenCode") + " anexada." + session + "]"
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
    Segurança → Gravação de Tela, com o OpenCode reaberto, só vejo a janela do OpenCode; enviei essa janela à mestra.
    """
  public static let deniedNotice = """
    Sem a permissão de Gravação de Tela só vejo a janela do OpenCode; enviei essa janela à mestra. Para ver outros \
    apps, libere o OpenCode em Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela.
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
    case .own: "da janela do OpenCode"
    case .window(let window):
      "da janela de \(window.app)" + (window.title.flatMap { $0.isEmpty ? nil : " (“\($0.prefix(120))”)" } ?? "")
    case .display(_, _, let front): "da tela inteira do Mac" + (front.map { " (\($0) na frente)" } ?? "")
    }
  }
}
