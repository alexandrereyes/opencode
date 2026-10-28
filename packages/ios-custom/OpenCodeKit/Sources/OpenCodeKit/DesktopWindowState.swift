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

  /// A window without saved state (a new one, or every window when macOS closes them on quit) opens Contexto at
  /// the width last chosen in any window.
  public static func load(window: UUID, server: URL, defaults: UserDefaults) -> Self {
    guard let data = defaults.data(forKey: key(window, server)),
      let state = try? JSONDecoder().decode(Self.self, from: data)
    else {
      var state = Self()
      let width = defaults.double(forKey: contextWidthKey)
      if width >= minimumContextWidth { state.contextWidth = width }
      return state
    }
    return state
  }

  public func save(window: UUID, server: URL, defaults: UserDefaults) {
    defaults.set(try? JSONEncoder().encode(self), forKey: Self.key(window, server))
  }

  public static let contextWidthKey = "OpenCodeMacContextWidth"
  public static let minimumContextWidth = 400.0
  /// Contexto may take up to this share of the window.
  public static let maximumContextShare = 0.6

  /// The width a drag of the divider ended at becomes the default for windows without saved state.
  public static func rememberContextWidth(_ width: Double, defaults: UserDefaults) {
    defaults.set(width, forKey: contextWidthKey)
  }

  /// How wide Contexto can be beside the chat: at least 400 pt, at most 60% of the window and never so wide that
  /// the chat (with the 1-pt divider) goes below its minimum.
  public static func contextWidthRange(detail: Double, window: Double, chatMinimum: Double) -> ClosedRange<Double> {
    minimumContextWidth...max(minimumContextWidth, min(window * maximumContextShare, detail - chatMinimum - 1))
  }

  private static func key(_ window: UUID, _ server: URL) -> String {
    "OpenCodeMacWindow.\(window.uuidString).\(server.absoluteString)"
  }
}
