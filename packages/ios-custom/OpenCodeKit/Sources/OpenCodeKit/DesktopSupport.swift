import Foundation

/// Moving through Sessões from the keyboard (the Mac's ⌘[ and ⌘]): the row before or after the current one, in the
/// order the column shows them. Without a current row it starts at the first (forward) or the last (backward).
public enum SessionNavigation {
  public static func neighbor(_ ids: [String], current: String?, offset: Int) -> String? {
    guard !ids.isEmpty, offset != 0 else { return nil }
    guard let current, let index = ids.firstIndex(of: current) else { return offset > 0 ? ids.first : ids.last }
    let next = index + offset
    return ids.indices.contains(next) ? ids[next] : nil
  }

  /// ⌘1…⌘9: the first rows the column shows, in its order, skipping collapsed sections.
  public static func numbered(_ sections: [SessionSection], collapse: SessionSectionCollapse, limit: Int = 9)
    -> [SessionRow]
  {
    Array(sections.filter { !collapse.collapsed($0.kind) }.flatMap(\.rows).prefix(limit))
  }
}

/// A system notification for an in-app session alert, shown by the Mac while the app is not in front: the
/// session's title, then the banner's label and, for an answer, its first line.
public struct SessionAlertNotification: Sendable, Equatable {
  public let title: String
  public let body: String

  public init(title: String, content: SessionAlertContent) {
    self.title = title
    body = [content.label, content.preview].compactMap { $0 }.joined(separator: "\n")
  }

  /// The Dock badge: the count of "Precisa de você" (`SessionAttention`), or none.
  public static func badge(_ count: Int) -> String? { count > 0 ? String(count) : nil }
}

/// A Mac key press for a resource in control (`ResourceInput`): named keys (Return, arrows, Backspace…) as DOM
/// `key` names with their modifiers, a character with Control as a `key` with modifiers, and typed text (Option
/// characters such as `ø` included) as `text`. Command shortcuts stay with the Mac (paste is handled by the viewer).
public enum ResourceKeyMapping {
  public struct Modifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1)
    public static let control = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let command = Self(rawValue: 8)
  }

  /// `kVK_*` virtual key codes of the keys with a DOM name.
  static let named: [UInt16: String] = [
    36: "Enter", 76: "Enter", 48: "Tab", 51: "Backspace", 117: "Delete", 53: "Escape",
    123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
    115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
  ]

  /// `characters` is what the key typed; `plain` the same key without modifiers (`charactersIgnoringModifiers`).
  public static func input(keyCode: UInt16, characters: String?, plain: String?, modifiers: Modifiers)
    -> ResourceInput?
  {
    guard !modifiers.contains(.command) else { return nil }
    let names = [(Modifiers.control, "Control"), (.option, "Alt"), (.shift, "Shift")]
      .filter { modifiers.contains($0.0) }.map(\.1)
    if let name = named[keyCode] { return .key(name, modifiers: names) }
    if modifiers.contains(.control) {
      guard let plain, printable(plain) else { return nil }
      return .key(plain, modifiers: names)
    }
    guard let characters, printable(characters) else { return nil }
    return .text(characters)
  }

  private static func printable(_ text: String) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
  }
}

/// Markdown files are often wrapped at a fixed width, and a soft line break is only a space. The Mac's block
/// renderer reads one line per paragraph or list item, so continuation lines are joined to the line they continue
/// (outside code fences; headings, list items, quotes, rules and table rows start their own line).
public enum MarkdownSoftBreaks {
  public static func unwrap(_ text: String) -> String {
    var lines: [String] = []
    var fenced = false
    var joinable = false
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fenced.toggle()
        lines.append(line)
        joinable = false
        continue
      }
      if fenced || trimmed.isEmpty {
        lines.append(line)
        joinable = false
        continue
      }
      let starts = trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || trimmed.hasPrefix("|")
        || trimmed.firstMatch(of: /^([-*+]|\d+[.)])\s/) != nil || trimmed.firstMatch(of: /^([-*_])\s*(\1\s*){2,}$/) != nil
      if joinable && !starts, let last = lines.popLast() {
        lines.append(last + " " + trimmed)
      } else {
        lines.append(line)
      }
      joinable = !(trimmed.hasPrefix("#") || trimmed.hasPrefix("|") || line.hasSuffix("  ")
        || trimmed.firstMatch(of: /^([-*_])\s*(\1\s*){2,}$/) != nil)
    }
    return lines.joined(separator: "\n")
  }

  /// The document in pieces of about `lines` lines, cut only at blank lines outside code fences, so a long file
  /// renders lazily piece by piece.
  public static func sections(_ text: String, lines limit: Int = 60) -> [String] {
    var sections: [String] = []
    var current: [String] = []
    var fenced = false
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle() }
      if !fenced, trimmed.isEmpty, current.count >= limit {
        sections.append(current.joined(separator: "\n"))
        current = []
        continue
      }
      current.append(line)
    }
    if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
    return sections
  }
}

/// The output of a background shell as it grows (`/api/shell/:id/output`), read by cursor. Only the last
/// `limit` bytes are kept: a long-running dev server would otherwise grow without end.
public struct ShellOutputLog: Sendable, Equatable {
  public private(set) var text = ""
  /// The next byte to ask for.
  public private(set) var cursor = 0
  /// Whether earlier output was skipped (the first read starts near the end, or old output was dropped).
  public private(set) var clipped = false
  public let limit: Int

  public init(limit: Int = 256 * 1024) { self.limit = limit }

  /// Where the first read starts once the size is known: the last `limit` bytes.
  public mutating func start(size: Int) {
    cursor = max(0, size - limit)
    clipped = cursor > 0
  }

  public mutating func append(_ chunk: ShellOutput) {
    guard chunk.cursor >= cursor else { return }
    text += chunk.output
    cursor = chunk.cursor
    let excess = text.utf8.count - limit
    guard excess > 0 else { return }
    // Drop whole lines from the start, so the view never begins mid-line.
    var dropped = text.utf8.dropFirst(excess)
    if let newline = dropped.firstIndex(of: UInt8(ascii: "\n")) { dropped = dropped[dropped.index(after: newline)...] }
    text = String(decoding: dropped, as: UTF8.self)
    clipped = true
  }
}
