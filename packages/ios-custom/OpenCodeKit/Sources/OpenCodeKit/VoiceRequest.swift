import Foundation

/// What the master is told of a voice request. On this route the delegation's text is the literal transcript of the
/// turn that delegated (02/11), errors included: GPT Live writes no request. OpenAI's live delegation guide says the
/// same of client delegations ("use transcript events and application state to prepare the backend request"), so the
/// app sends that speech plus the completed turns of this conversation since the previous delegation, which the master
/// has not seen: the newest, at most `limit` of them and about `characters`, labelled as a transcript. Same rule as the
/// Watch's `masterRequest` in `plugin-app-custom` (`src/watch/delegation.ts`).
public struct VoiceRequestContext: Sendable {
  public static let limit = 6
  public static let characters = 1_200
  public static let label = "Conversa por voz desde o pedido anterior (transcrição, pode ter erros):"
  struct Turn: Sendable, Equatable {
    let id: String?
    let role: VoiceMemoryTurn.Role
    let text: String
  }
  private(set) var pending: [Turn] = []
  /// The user turn the last request came from: its `turn.done` usually arrives after the delegation and is not
  /// context for the next one.
  private var trigger: (id: String?, key: String)?
  public init() {}

  public mutating func heard(_ turn: VoiceCompletedTurn) {
    guard let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
    if turn.role == .user, let trigger, Self.same(trigger, id: turn.id, text: text) { self.trigger = nil; return }
    if let id = turn.id, pending.contains(where: { $0.id == id }) { return }
    pending.append(Turn(id: turn.id, role: turn.role, text: text))
    if pending.count > Self.limit { pending.removeFirst(pending.count - Self.limit) }
  }

  /// What Alexandre last finished saying, for a delegation that came without text.
  public var lastUser: String? { pending.last { $0.role == .user }?.text }

  /// The request for `speech`, delegated from the user turn `turn`; the turns heard so far go with it, once.
  public mutating func request(_ speech: String, turn: String?) -> String {
    let speech = speech.trimmingCharacters(in: .whitespacesAndNewlines)
    let trigger = (id: turn, key: VoiceContinuity.key(speech))
    let context = pending.filter { !($0.role == .user && Self.same(trigger, id: $0.id, text: $0.text)) }
    pending = []; self.trigger = trigger
    var lines: [String] = []
    var used = 0
    for turn in context.reversed() {
      let name = turn.role == .user ? "Alexandre: " : "Voz: "
      let room = Self.characters - used - name.count
      guard turn.text.count <= room else {
        // The newest turn alone fills the budget: its end, nearest to the request.
        if lines.isEmpty { lines.append(name + "…" + turn.text.suffix(room - 1)) }
        break
      }
      lines.append(name + turn.text); used += name.count + turn.text.count + 1
    }
    guard !lines.isEmpty else { return speech }
    return speech + "\n\n" + Self.label + "\n" + lines.reversed().joined(separator: "\n")
  }

  /// The same turn: by ID when both have one, else by its words.
  private static func same(_ trigger: (id: String?, key: String), id: String?, text: String) -> Bool {
    if let id, let other = trigger.id { return id == other }
    return VoiceContinuity.key(text) == trigger.key
  }
}

/// Whether Alexandre asked to queue a request behind the master's current work ("enfileira", "coloca na fila", "sem
/// interromper"); otherwise it steers. The route never sends the `"delivery"` field the prompt used to describe, so the
/// app decides from his words, with a narrow net like `VoiceScreenIntent`; case and accents do not matter. Same rule as
/// the Watch's `queues` in `plugin-app-custom` (`src/watch/delegation.ts`).
public enum VoiceQueueIntent {
  private static let patterns = [
    #"\benfileir(a|ar|e)\b"#, #"\b(coloca|poe)( \w+){0,2} na fila\b"#, #"\bsem interromper\b"#,
  ].map { try! NSRegularExpression(pattern: $0) }

  public static func queues(_ text: String) -> Bool {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let range = NSRange(folded.startIndex..., in: folded)
    return patterns.contains { $0.firstMatch(in: folded, range: range) != nil }
  }
}
