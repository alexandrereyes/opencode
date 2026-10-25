import CoreGraphics
import Foundation

/// State of a mirrored Chrome tab, from the hub's `meta` messages (`ChromeState` in the plugin's Chrome adapter).
public struct ChromeViewerState: Decodable, Equatable, Sendable {
  public var url: String
  public var title: String
  public var canGoBack: Bool
  public var canGoForward: Bool
  public var targetID: String
  public var tabs: [ChromeTab]
  public var focus: ChromeFocus
  /// Counts taps on editable fields, so the keyboard reopens on a field that kept the focus.
  public var editTaps: Int
  /// CSS pixels of the mirrored viewport.
  public var viewport: CGSize?

  public init(url: String = "", title: String = "", canGoBack: Bool = false, canGoForward: Bool = false,
              targetID: String = "", tabs: [ChromeTab] = [], focus: ChromeFocus = .none, editTaps: Int = 0,
              viewport: CGSize? = nil) {
    self.url = url
    self.title = title
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.targetID = targetID
    self.tabs = tabs
    self.focus = focus
    self.editTaps = editTaps
    self.viewport = viewport
  }

  /// The state from the viewer's merged `meta` messages; missing or malformed fields keep their defaults.
  public init(meta: [String: JSONValue]) {
    let decoded = (try? JSONEncoder().encode(meta)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    self = decoded ?? Self()
  }

  private enum Keys: String, CodingKey { case url, title, canGoBack, canGoForward, targetID, tabs, focus, editTaps, viewport }
  private struct Size: Decodable { let width: Double; let height: Double }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    canGoBack = try container.decodeIfPresent(Bool.self, forKey: .canGoBack) ?? false
    canGoForward = try container.decodeIfPresent(Bool.self, forKey: .canGoForward) ?? false
    targetID = try container.decodeIfPresent(String.self, forKey: .targetID) ?? ""
    tabs = (try? container.decodeIfPresent([ChromeTab].self, forKey: .tabs)) ?? []
    focus = (try? container.decodeIfPresent(ChromeFocus.self, forKey: .focus)) ?? .none
    editTaps = (try? container.decodeIfPresent(Int.self, forKey: .editTaps)) ?? 0
    viewport = (try? container.decodeIfPresent(Size.self, forKey: .viewport)).map {
      CGSize(width: $0.width, height: $0.height)
    }
  }

  /// `localhost:5173/login`: host and path, like Safari's compact address.
  public var displayAddress: String { Self.displayAddress(url) }

  public static func displayAddress(_ url: String) -> String {
    guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else { return url }
    let port = components.port.map { ":\($0)" } ?? ""
    let path = components.path == "/" ? "" : components.path
    return host + port + path
  }

  /// HTTPS or a loopback origin, which browsers also treat as a secure context.
  public var isSecure: Bool {
    guard let components = URLComponents(string: url), let host = components.host?.lowercased() else { return false }
    if components.scheme == "https" { return true }
    return components.scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1")
  }
}

public struct ChromeTab: Decodable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let url: String

  public init(id: String, title: String, url: String) {
    self.id = id
    self.title = title
    self.url = url
  }
}

/// The page's focused field, so the iPhone shows the matching keyboard. The plugin never sends field values.
public struct ChromeFocus: Decodable, Equatable, Sendable {
  public enum Field: String, Decodable, Sendable {
    case text, multiline, password, email, username, url, tel, number, search
    case oneTimeCode = "one-time-code"
  }

  public let editable: Bool
  public let field: Field?

  public static let none = ChromeFocus(editable: false, field: nil)

  public init(editable: Bool, field: Field?) {
    self.editable = editable
    self.field = editable ? (field ?? .text) : nil
  }

  private enum Keys: String, CodingKey { case editable, field }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    let editable = try container.decodeIfPresent(Bool.self, forKey: .editable) ?? false
    self.init(editable: editable, field: editable ? ((try? container.decode(Field.self, forKey: .field)) ?? .text) : nil)
  }
}

/// Keyboard traits for a focused page field. The app maps them to `UITextContentType` and `UIKeyboardType`; secure
/// entry with the password content type makes iOS offer saved passwords (AutoFill).
public struct ChromeKeyboard: Equatable, Sendable {
  public enum ContentType: Equatable, Sendable { case none, password, username, email, url, telephone, oneTimeCode }
  /// Number fields use a keyboard that still has Return, so forms can be submitted.
  public enum Keyboard: Equatable, Sendable { case standard, email, url, numbers, webSearch }

  public let contentType: ContentType
  public let keyboard: Keyboard
  public let secure: Bool

  public init(_ field: ChromeFocus.Field) {
    switch field {
    case .password: self.init(.password, .standard, secure: true)
    case .username: self.init(.username, .email)
    case .email: self.init(.email, .email)
    case .url: self.init(.url, .url)
    case .tel: self.init(.telephone, .numbers)
    case .number: self.init(.none, .numbers)
    case .search: self.init(.none, .webSearch)
    case .oneTimeCode: self.init(.oneTimeCode, .numbers)
    case .text, .multiline: self.init(.none, .standard)
    }
  }

  init(_ contentType: ContentType, _ keyboard: Keyboard, secure: Bool = false) {
    self.contentType = contentType
    self.keyboard = keyboard
    self.secure = secure
  }
}
