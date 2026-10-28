import Foundation

/// The text and reasoning streamed into running messages, recorded as events arrive whether or not they are
/// applied to the transcript at that moment, and whether or not the conversation is on screen.
///
/// A read of a running message does not carry the text its deltas already streamed (the server keeps a part's
/// text when the part ends), and deltas that arrive while a read is in flight are not applied, since the read
/// may already include them. Reconciling a read with this log restores what it lacks without repeating what it
/// has. A part whose beginning streamed before this log saw it shows what arrived since, after a marker, and
/// its end event brings the whole text. When deltas were lost in the middle of a part (the event stream
/// disconnected), the part keeps the text it showed and takes no further deltas until its end event: the
/// reader sees the answer pause, never a gap in it.
public struct ConversationStreamLog: Sendable {
  /// Shown before the text of a part whose beginning streamed before this log saw it.
  public static let missingStart = "…"

  struct Key: Hashable, Sendable {
    let message: String
    let kind: String
    let ordinal: Int
  }
  private var texts: [Key: String] = [:]
  /// Lost deltas in their middle: they keep their text until their end event.
  private var frozen: Set<Key> = []
  /// Began before this log saw them: their text is what arrived since.
  private var headless: Set<Key> = []
  private var ended: Set<Key> = []
  /// The last event frame recorded: several feeds (the screen's and the session list's) record the same frames.
  private var sequence = 0

  public init() {}

  /// Records a text or reasoning event of this conversation. Feeds that see the same frames in order pass
  /// their sequence, so a frame another feed already recorded is not recorded twice.
  public mutating func record(_ event: ConversationEvent, sequence: Int? = nil) {
    guard let key = key(event) else { return }
    if let sequence {
      guard sequence > self.sequence else { return }
      self.sequence = sequence
    }
    switch event.type {
    case let type where type.hasSuffix(".started"):
      texts[key] = ""
      frozen.remove(key)
      headless.remove(key)
      ended.remove(key)
    case let type where type.hasSuffix(".delta"):
      guard !frozen.contains(key), !ended.contains(key) else { return }
      let delta = event.data.delta?.string ?? ""
      guard let text = texts[key] else {
        texts[key] = delta
        headless.insert(key)
        return
      }
      texts[key] = text + delta
    case let type where type.hasSuffix(".ended"):
      texts[key] = event.data.text ?? texts[key]
      frozen.remove(key)
      headless.remove(key)
      ended.insert(key)
    default: break
    }
  }

  /// Whether the event may be applied to the transcript as it is: deltas of a part that lost some are held
  /// back, and those of a part without its beginning reach the transcript through `reconcile`.
  public func accepts(_ event: ConversationEvent) -> Bool {
    guard event.type.hasSuffix(".delta"), let key = key(event) else { return true }
    return !frozen.contains(key) && !headless.contains(key)
  }

  /// Messages with a part shown without its beginning: reconcile them after applying their events.
  public var headlessMessages: Set<String> { Set(headless.map(\.message)) }

  /// The event stream disconnected: deltas sent meanwhile are gone, so every part still streaming keeps the
  /// text it shows until its end event.
  public mutating func interrupt(_ messages: [ConversationMessage]) {
    for message in messages where message.time.completed == nil {
      for (key, text) in parts(message) {
        if !headless.contains(key), (texts[key]?.count ?? 0) < text.count { texts[key] = text }
        frozen.insert(key)
      }
    }
    frozen.formUnion(texts.keys.filter { !ended.contains($0) })
  }

  /// A read of a running message, with each text and reasoning part extended to the streamed text that begins
  /// with what was read. Parts the read does not have yet follow in order. Reads of finished messages are final.
  public mutating func reconcile(_ message: ConversationMessage) -> ConversationMessage {
    guard message.time.completed == nil else {
      texts = texts.filter { $0.key.message != message.id }
      frozen = frozen.filter { $0.message != message.id }
      headless = headless.filter { $0.message != message.id }
      ended = ended.filter { $0.message != message.id }
      return message
    }
    var reconciled = message
    var content = message.content ?? []
    for kind in ["text", "reasoning"] {
      let positions = content.indices.filter { content[$0].type == ConversationPartKind(kind) }
      for (ordinal, position) in positions.enumerated() {
        let key = Key(message: message.id, kind: kind, ordinal: ordinal)
        let read = content[position].text ?? ""
        guard let streamed = texts[key] else { continue }
        if ended.contains(key) {
          content[position].text = streamed
        } else if headless.contains(key) {
          if read.isEmpty || read.hasPrefix(Self.missingStart) {
            content[position].text = Self.headless(streamed)
          } else {
            // The read carries this part's text after all: keep it, and wait for the end.
            headless.remove(key)
            frozen.insert(key)
            texts[key] = read
          }
        } else if streamed.count > read.count, streamed.hasPrefix(read) {
          content[position].text = streamed
        }
      }
      var ordinal = positions.count
      while let streamed = texts[Key(message: message.id, kind: kind, ordinal: ordinal)] {
        let key = Key(message: message.id, kind: kind, ordinal: ordinal)
        content.append(ConversationPart(type: kind, text: headless.contains(key) ? Self.headless(streamed) : streamed))
        ordinal += 1
      }
    }
    reconciled.content = content
    return reconciled
  }

  /// What a part without its beginning shows: the marker, then its text from the first whole line on. The
  /// fragment before it would make the rest one paragraph (a list continuing mid-way cannot interrupt it).
  static func headless(_ text: String) -> String {
    guard let newline = text.firstIndex(of: "\n") else { return missingStart + text }
    return missingStart + "\n\n" + text[text.index(after: newline)...].drop { $0.isNewline }
  }

  private func key(_ event: ConversationEvent) -> Key? {
    let kind: String
    if event.type.hasPrefix("session.text.") { kind = "text" }
    else if event.type.hasPrefix("session.reasoning.") { kind = "reasoning" }
    else { return nil }
    guard let message = event.data.assistantMessageID, let ordinal = event.data.ordinal else { return nil }
    return Key(message: message, kind: kind, ordinal: ordinal)
  }

  private func parts(_ message: ConversationMessage) -> [(Key, String)] {
    ["text", "reasoning"].flatMap { kind in
      (message.content ?? []).filter { $0.type == ConversationPartKind(kind) }.enumerated().map {
        (Key(message: message.id, kind: kind, ordinal: $0.offset), $0.element.text ?? "")
      }
    }
  }
}
