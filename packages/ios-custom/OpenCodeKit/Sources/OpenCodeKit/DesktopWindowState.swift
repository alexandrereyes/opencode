import Foundation

/// Restorable presentation of one desktop window, namespaced by both its scene identity and server.
public struct DesktopWindowState: Codable, Equatable, Sendable {
  public struct Selection: Codable, Equatable, Sendable {
    public struct Files: Codable, Equatable, Sendable {
      public var folder: String?
      public var file: String?
      public init(folder: String? = nil, file: String? = nil) { self.folder = folder; self.file = file }
    }
    public var sessionID: String?
    public var childID: String?
    public var files: Files?
    public var master: Bool
    public init(sessionID: String? = nil, childID: String? = nil, files: Files? = nil, master: Bool = false) {
      self.sessionID = sessionID
      self.childID = childID
      self.files = files
      self.master = master
    }
  }
  public var selection = Selection()
  public var contextVisible = true
  public var sidebarVisible = true
  public var contextWidth = 520.0
  public init() {}

  public static func load(window: UUID, server: URL, defaults: UserDefaults) -> Self {
    guard let data = defaults.data(forKey: key(window, server)),
      let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
    return state
  }

  public func save(window: UUID, server: URL, defaults: UserDefaults) {
    defaults.set(try? JSONEncoder().encode(self), forKey: Self.key(window, server))
  }

  private static func key(_ window: UUID, _ server: URL) -> String {
    "OpenCodeMacWindow.\(window.uuidString).\(server.absoluteString)"
  }
}
