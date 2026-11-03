import Foundation

/// The quick server switch of both apps, from the saved servers alone: the server title atop Sessões (avatar, name and
/// the current server's connection), its server list (an iPhone sheet, a Mac panel) and the Mac's Ir ▸ Servidores.
/// The other servers' state needs connections of their own and is not shown.
public enum ServerSwitcher {
  /// ⌃⌘1…⌃⌘9, in Ajustes' order; servers past the ninth have no shortcut.
  public static let shortcuts = 9

  public struct Entry: Identifiable, Equatable, Sendable {
    public let server: SavedServer
    public let initials: String
    /// A theme avatar color (`AppTheme.avatar`), chosen from the server's ID like a project without a color.
    public let color: String
    public let address: String
    public let active: Bool
    public let shortcut: Int?
    public var id: String { server.id }
  }

  /// The current server's connection, worded like Ajustes ▸ Servidores.
  public enum Connection: Equatable, Sendable {
    case connected, connecting, disconnected

    public init(connected: Bool, failed: Bool) {
      self = connected ? .connected : failed ? .disconnected : .connecting
    }

    public var label: String {
      switch self {
      case .connected: "Conectado"
      case .connecting: "Conectando…"
      case .disconnected: "Desconectado"
      }
    }

    /// The dot beside the server's name.
    public var role: ThemeRole {
      switch self {
      case .connected: .success
      case .connecting: .warning
      case .disconnected: .error
      }
    }
  }

  /// Only when there is a choice: with one saved server the Mac's Ir ▸ Servidores and its ⌃⌘ shortcuts stay out.
  /// The server title shows in any case.
  public static func visible(_ servers: [SavedServer]) -> Bool { servers.count > 1 }

  public static func entries(_ servers: [SavedServer], activeID: String) -> [Entry] {
    servers.enumerated().map { index, server in
      Entry(server: server, initials: initials(server.title), color: SessionList.avatarColor(nil, fallback: server.id),
        address: address(server.url), active: server.id == activeID, shortcut: index < shortcuts ? index + 1 : nil)
    }
  }

  /// Two letters, like a project's monogram, skipping the joining words of a name: "Mac de Alexandre" is MA,
  /// "host-6 · produção" H6 and "Sandbox" SA.
  public static func initials(_ title: String) -> String {
    let words = title.split { !$0.isLetter && !$0.isNumber }
    let named = words.filter { !joining.contains($0.lowercased()) }
    return SessionList.monogram((named.isEmpty ? words : named).joined(separator: " "))
  }

  /// Host and port, with the path of a server behind a proxy: `127.0.0.1:4096`, `mac.example.com/opencode`.
  public static func address(_ url: URL) -> String {
    let host = (url.host() ?? url.absoluteString) + (url.port.map { ":\($0)" } ?? "")
    return url.path().isEmpty || url.path() == "/" ? host : host + url.path()
  }

  private static let joining: Set<String> = ["de", "da", "do", "das", "dos", "e", "of", "the", "and"]
}
