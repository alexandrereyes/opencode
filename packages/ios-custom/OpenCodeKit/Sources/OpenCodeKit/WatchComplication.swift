import Foundation

/// The attention complication (rev. 2026-11-01): which kinds of priority attention wait, never how many, so only a
/// kind appearing or clearing changes what it draws and pushes it (the plugin's `watch/widget.ts` key mirrors
/// `kinds`). Working sessions, unread answers, finished ones and the totals stay in the Painel and the Live Activity.
public struct WatchAttention: Equatable, Sendable {
  /// In the backend's status precedence: the circular and corner families show the first one waiting.
  public enum Kind: String, CaseIterable, Sendable {
    case question, permission, failed

    public var role: ThemeRole {
      switch self {
      case .question: .accent
      case .permission: .warning
      case .failed: .error
      }
    }

    /// Filled glyphs with the mark cut out, so the shape still tells the kinds apart on a tinted face.
    public var symbol: String {
      switch self {
      case .question: "questionmark.bubble.fill"
      case .permission: "hand.raised.fill"
      case .failed: "exclamationmark.triangle.fill"
      }
    }

    /// The corner's curved label, and the rectangular line's parts when several kinds wait.
    public var label: String {
      switch self {
      case .question: "Pergunta"
      case .permission: "Permissão"
      case .failed: "Erro"
      }
    }

    /// The rectangular line when it is the only kind waiting.
    public var line: String {
      switch self {
      case .question: "Pergunta esperando"
      case .permission: "Permissão pendente"
      case .failed: "Sessão com erro"
      }
    }
  }

  public let kinds: [Kind]

  public init(_ state: AgentsState?) {
    let counts = state?.counts
    kinds = Kind.allCases.filter { kind in
      switch kind {
      case .question: (counts?.question ?? 0) > 0
      case .permission: (counts?.permission ?? 0) > 0
      case .failed: (counts?.failed ?? 0) > 0
      }
    }
  }

  public var top: Kind? { kinds.first }
  public var cornerLabel: String { top?.label ?? "OpenCode" }
  /// `Pergunta esperando`, `Pergunta · Erro`, or `Nada para você`.
  public var line: String {
    guard let top else { return "Nada para você" }
    return kinds.count == 1 ? top.line : kinds.map(\.label).joined(separator: " · ")
  }

  /// `OpenCode: pergunta esperando`, `OpenCode: pergunta, permissão e erro`, or nothing waiting.
  public var accessibilityLabel: String {
    guard let top else { return "OpenCode: nada precisa de você" }
    guard kinds.count > 1 else { return "OpenCode: " + top.line.lowercased() }
    let labels = kinds.map { $0.label.lowercased() }
    return "OpenCode: " + labels.dropLast().joined(separator: ", ") + " e " + (labels.last ?? "")
  }
}

/// Where the system opens the watch app from outside (rev. 2026-11-01). The attention complication and the agents
/// Live Activity in the Smart Stack open the Painel; the "Falar" complication opens Voz and starts a call there.
public enum WatchLaunch: String, Equatable, Sendable {
  case dashboard = "painel"
  case voice = "voz"

  /// Registered by the watch app (`CFBundleURLTypes`) for its complications' `widgetURL`; the iPhone app's is
  /// `AgentsDeepLink.scheme`.
  public static let scheme = "br.com.alexandrem.opencode.watch"

  public var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

  /// Only `<scheme>://voz` opens Voz: any other URL, such as the iPhone deep link the agents Live Activity carries,
  /// opens the Painel.
  public init(url: URL) {
    self = url.scheme == Self.scheme && url.host == Self.voice.rawValue ? .voice : .dashboard
  }

  /// The watch's call as far as a launch is concerned.
  public enum Call: Sendable {
    case idle
    /// Connecting or live.
    case active
    /// Failed or ended by the service, its notice still on screen.
    case finished
  }

  public enum Action: String, Equatable, Sendable {
    /// Back to the Painel, closing Responder.
    case dashboard
    /// Leave the call screen as it is.
    case showCall
    /// Start a call (`Tentar de novo`'s start) and show it.
    case startCall
  }

  /// A launch never interrupts a call: the Painel waits while one is connecting, live, or still shows why it ended;
  /// "Falar" returns to the call in progress instead of starting another, and needs a pairing to start one.
  public func action(call: Call, paired: Bool) -> Action {
    switch (self, call) {
    case (_, .active): .showCall
    case (.dashboard, .finished): .showCall
    case (.dashboard, .idle): .dashboard
    case (.voice, .idle), (.voice, .finished): paired ? .startCall : .dashboard
    }
  }
}
