import Foundation

public struct VoiceTranscriptPiece: Equatable, Sendable {
  public let id: String?
  public let text: String
}

public struct VoiceCompletedTurn: Equatable, Sendable {
  public let id: String?
  public let itemID: String?
  public let role: VoiceMemoryTurn.Role
  public let text: String?
  public let interrupted: Bool
}

public enum VoiceEvent: Equatable, Sendable {
  /// `session.started`: GPT Live's ID of the call (`session.id`, the last segment of the creation's `Location` on
  /// 02/11) and when the session expires (`expires_at`, epoch seconds: the creation plus 2 h), when sent.
  case ready(call: String? = nil, expiresAt: Double? = nil)
  case input(VoiceTranscriptPiece), output(VoiceTranscriptPiece), turnDone(VoiceCompletedTurn)
  /// A delegation: its item, its text (on this route the transcript of the turn that delegated) and that user turn's
  /// ID (`user_bidi_turn_id`), when sent.
  case delegation(id: String, text: String, turn: String? = nil)
  /// `failure` carries GPT Live's error `type/code`, its message and `param` sanitized for diagnostics
  /// (`VoiceDiagnosticText`), and the `event_id` of the app's command it is about (`error.event_id`).
  case failure(code: String?, detail: String? = nil, command: String? = nil), ignored
  /// GPT Live took an append: the context reached the model, which is not to say it was spoken.
  case appended(VoiceContextTarget)
  /// GPT Live closed the session (`session.closed`): its `reason` and the audio it counted (`usage.audio_duration_ms`),
  /// when sent.
  case closed(reason: String? = nil, audioMs: Int? = nil)
  /// A delegation without a readable text: the app falls back to what Alexandre is saying or last said, else it is
  /// answered so GPT Live asks him again.
  case unreadableDelegation(id: String, turn: String? = nil)
}

/// How GPT Live takes appended context. The route refuses OpenAI's `session.commentary.append` (spoken) and
/// `session.thinking.append` (quiet); its `speakable` is said within a second, and `commentary` is its closest quiet
/// form: on 02/11 neutral facts sent on it stayed quiet and were used when asked, while news ("a etapa terminou") was
/// said anyway, so it is never a guaranteed silence.
public enum VoiceChannel: String, Sendable { case speakable, commentary }

/// What an append adds to: one delegation (`delegation.context.append`) or the whole call (`session.context.append`).
public enum VoiceContextTarget: Hashable, Sendable { case session, delegation(String) }

/// One command for the data channel, with the `event_id` the app gave it.
public struct VoiceCommand: Sendable, Equatable {
  public let id: String
  public let type: String
  /// What an append adds to, as its confirmation names it; nil for a command GPT Live does not confirm.
  public let target: VoiceContextTarget?
  public let data: Data
}

/// GPT Live's wire as the apps reach it: the Codex route (`OpenAI-Alpha: quicksilver=v2`), not OpenAI's public Live
/// API. The data channel's events, commands and field names and the creation's body live here, and `VoiceSignaling`
/// keeps the HTTP transport (URL, query, headers, lease), so moving to the official API changes these two files;
/// `docs/voice.md` ("Rota do Codex e API oficial") maps each name. The Watch's gateway has the same wire in
/// `plugin-app-custom/src/watch/protocol.ts`.
public enum VoiceProtocol {
  /// The data channel GPT Live reads and writes, created before the offer.
  public static let dataChannel = "oai-events"
  public static let model = "gpt-live-1-codex"

  /// The creation's body: the offer and the `session`, with client delegation (GPT Live hands the work to the app)
  /// and, when there are any, `initial_items`.
  public static func creation(sdp: String, instructions: String, voice: GPTLiveVoice, items: [VoiceInitialItem]) throws -> Data {
    var session: [String: JSONValue] = [
      "model": .string(model), "instructions": .string(instructions),
      "audio": .object(["output": .object(["voice": .string(voice.rawValue)])]),
      "delegation": .object(["type": .string("client")]),
    ]
    if !items.isEmpty { session["initial_items"] = .array(items.map(message)) }
    return try JSONEncoder().encode(JSONValue.object(["sdp": .string(sdp), "session": .object(session)]))
  }

  /// A turn keeps who said it, the assistant's as `output_text`; what the app tells GPT Live is a `developer` message,
  /// which the route accepts in `initial_items` (02/11).
  static func message(_ item: VoiceInitialItem) -> JSONValue {
    .object(["type": .string("message"), "role": .string(item.role.rawValue), "content": .array([.object([
      "type": .string(item.role == .assistant ? "output_text" : "input_text"), "text": .string(item.text)])])])
  }

  /// A creation refused for its voice: only this proves no call was created, so another voice is tried.
  public static func rejectsVoice(_ data: Data, status: Int) -> Bool {
    guard [400, 422].contains(status), data.count <= 256 * 1024,
      let root = try? JSONDecoder().decode(JSONValue.self, from: data).object else { return false }
    if let error = root["error"]?.object {
      if ["invalid_voice", "unsupported_voice"].contains(error["code"]?.string ?? "") { return true }
      if error["type"]?.string == "invalid_request_error",
        ["session.audio.output.voice", "audio.output.voice", "voice"].contains(error["param"]?.string ?? "") { return true }
    }
    return root["detail"]?.array?.contains { error in
      let path = error.object?["loc"]?.array?.compactMap(\.string) ?? []
      return Array(path.suffix(4)) == ["session", "audio", "output", "voice"]
        && ["enum", "literal_error", "value_error"].contains(error.object?["type"]?.string ?? "")
    } == true
  }

  /// The event's `type`, for the diagnostics trail; nil when the payload is not a JSON object with one.
  public static func eventType(_ data: Data) -> String? {
    guard data.count <= 256 * 1024 else { return nil }
    return (try? JSONDecoder().decode(JSONValue.self, from: data))?.object?["type"]?.string
  }

  public static func decode(_ data: Data) throws -> VoiceEvent {
    guard data.count <= 256 * 1024 else { throw VoiceWireError.oversized }
    let root = try JSONDecoder().decode(JSONValue.self, from: data).object
    guard let type = root?["type"]?.string else { throw VoiceWireError.invalidEvent }
    switch type {
    case "session.started":
      let session = root?["session"]?.object
      return .ready(call: session?["id"]?.string.flatMap { $0.isEmpty || $0.utf8.count > 1024 ? nil : $0 },
        expiresAt: session?["expires_at"]?.number)
    case "input_transcript.added", "output_transcript.added":
      guard let text = root?["item"]?.object?["text"]?.string else { throw VoiceWireError.invalidEvent }
      let piece = VoiceTranscriptPiece(id: root?["item"]?.object?["id"]?.string, text: text)
      return type.hasPrefix("input") ? .input(piece) : .output(piece)
    case "turn.done":
      guard let role = root?["turn"]?.object?["role"]?.string,
        ["assistant", "user", "input"].contains(role) else { throw VoiceWireError.invalidEvent }
      let turn = root?["turn"]?.object
      return .turnDone(.init(id: turn?["id"]?.string, itemID: turn?["item_id"]?.string ?? turn?["item"]?.object?["id"]?.string,
        role: role == "assistant" ? .assistant : .user, text: turn?["transcript"]?.string,
        interrupted: turn?["interrupted"]?.bool == true || ["interrupted", "cancelled"].contains(turn?["status"]?.string ?? "")))
    case "delegation.created":
      guard let item = root?["item"]?.object, item["target"]?.string == "client" else { return .ignored }
      guard item["type"]?.string == "delegation", let id = item["id"]?.string, !id.isEmpty, id.utf8.count <= 1024 else {
        throw VoiceWireError.invalidEvent
      }
      let text = (item["content"]?.array ?? []).compactMap { part -> String? in
        guard part.object?["type"]?.string == "input_text" else { return nil }
        return part.object?["text"]?.string
      }.joined()
      let turn = item["user_bidi_turn_id"]?.string.flatMap { $0.isEmpty || $0.utf8.count > 1024 ? nil : $0 }
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_768 else {
        return .unreadableDelegation(id: id, turn: turn)
      }
      return .delegation(id: id, text: text, turn: turn)
    // Confirmations carry no `event_id` (02/11): the session's answers its oldest append still waiting, a delegation's
    // the oldest of its item (`VoiceCommandLog.confirmed`).
    case "session.context.appended": return .appended(.session)
    case "delegation.context.appended":
      guard let id = root?["delegation_item_id"]?.string, !id.isEmpty else { throw VoiceWireError.invalidEvent }
      return .appended(.delegation(id))
    case "error":
      // Fields nested in `error` or, failing that, at the top level, whose `type` is the event's own.
      let error = root?["error"]?.object
      func field(_ name: String) -> String? { (error?[name] ?? (name == "type" ? nil : root?[name]))?.string }
      let code = [field("type"), field("code")].compactMap { $0 }.joined(separator: "/")
      // Ours is `error.event_id`, the command the error is about; the event's own `event_id` is the service's (02/11).
      return .failure(code: code.isEmpty ? nil : code,
        detail: VoiceDiagnosticText.detail(message: field("message") ?? root?["error"]?.string, param: field("param")),
        command: error?["event_id"]?.string.flatMap { $0.utf8.count > 128 ? nil : $0 })
    case "session.closed":
      return .closed(reason: root?["reason"]?.string,
        audioMs: root?["usage"]?.object?["audio_duration_ms"]?.number.flatMap { Int(exactly: $0) })
    default: return .ignored
    }
  }

  /// Asks GPT Live to end the session; it answers `session.closed`, then closes the data channel (02/11: 0.55 s and
  /// 1.1 s, nothing else in between).
  public static func close() -> VoiceCommand { command("session.close", target: nil, [:]) }

  /// Whether a GPT Live error means its session is over. OpenAI's Realtime reference: "Most errors are recoverable
  /// and the session will stay open"; openai/codex, on this same protocol, ends a call only when the transport
  /// closes. The one that kills it is `session_expired`, sent when the session reaches its maximum duration.
  public static func endsSession(_ code: String?) -> Bool {
    code?.split(separator: "/").contains("session_expired") == true
  }

  /// GPT Live's moderation (`content_filter`), by the error's structured `type/code` only, never its message. OpenAI's
  /// live conversations guide: some moderations end the session, others only cut the current speech; on 31/10 and 01/11
  /// the data channel closed within a second.
  public static func isModeration(_ code: String?) -> Bool {
    code?.split(separator: "/").contains("content_filter") == true
  }

  /// A `session.closed` reason that names content moderation. OpenAI documents `content`; this route was only seen
  /// sending `client_request` (02/11), so any reason that mentions content or moderation counts.
  public static func closedByModeration(_ reason: String?) -> Bool {
    guard let reason = reason?.lowercased() else { return false }
    return reason.contains("content") || reason.contains("moderat")
  }

  public static func append(id: String, text: String, channel: VoiceChannel = .speakable) throws -> [VoiceCommand] {
    guard !id.isEmpty, id.utf8.count <= 1024 else { throw VoiceWireError.oversized }
    return try chunks(text).map {
      command("delegation.context.append", target: .delegation(id),
        ["delegation_item_id": .string(id), "channel": .string(channel.rawValue), "content": content($0)])
    }
  }

  /// Context for the whole call rather than one delegation: how a rebuilt call hears a result its delegation, left
  /// in the lost call, can no longer carry. The service accepts it with text (29/10, `missing_required_parameter:
  /// content[0].text` for an image); without a channel it is `speakable`, and on 02/11 such a fact was said within a
  /// second.
  public static func contextAppend(_ text: String) throws -> [VoiceCommand] {
    try chunks(text).map { command("session.context.append", target: .session, ["content": content($0)]) }
  }

  private static func content(_ text: String) -> JSONValue {
    .array([.object(["type": .string("input_text"), "text": .string(text)])])
  }

  /// Every command carries an `event_id` of the app's, `oc_` and 16 hex digits: GPT Live takes one on any command and
  /// returns it in an `error` about that command, never in a confirmation (02/11).
  private static func command(_ type: String, target: VoiceContextTarget?, _ fields: [String: JSONValue]) -> VoiceCommand {
    let id = "oc_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    var object = fields
    object["type"] = .string(type); object["event_id"] = .string(id)
    // Strings, arrays and objects only: encoding them cannot fail.
    return VoiceCommand(id: id, type: type, target: target, data: (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data())
  }

  /// At most 500 UTF-8 bytes per part, never splitting a scalar.
  private static func chunks(_ text: String) throws -> [String] {
    guard !text.isEmpty, text.utf8.count <= 65_536 else { throw VoiceWireError.oversized }
    var chunks: [String] = []
    var chunk = ""
    for scalar in text.unicodeScalars {
      if chunk.utf8.count + scalar.utf8.count > 500 { chunks.append(chunk); chunk = "" }
      chunk.unicodeScalars.append(scalar)
    }
    if !chunk.isEmpty { chunks.append(chunk) }
    return chunks
  }
}

/// The commands sent on one GPT Live call, the newest `capacity`, by their `event_id`: which one an `error` names, and
/// which appends GPT Live took. Its confirmations carry no ID (02/11): `session.context.appended` answers the oldest
/// session append still waiting, `delegation.context.appended` the oldest of its item; an append an error named never
/// gets one.
public struct VoiceCommandLog: Sendable {
  /// Why the app sent it: an update or result to say, the master's quiet state, the app's own answer to a delegation,
  /// or a result as the call's context after a rebuild.
  public enum Purpose: String, Sendable { case narration, status, answer, context }
  public struct Entry: Sendable, Equatable {
    public let id: String
    public let type: String
    public let at: Double
    public let purpose: Purpose
    let target: VoiceContextTarget?
    /// An append GPT Live has neither confirmed nor refused.
    var waiting: Bool
  }
  public static let capacity = 64
  private var entries: [Entry] = []
  public init() {}

  public mutating func record(_ command: VoiceCommand, purpose: Purpose, at: Double) {
    entries.append(Entry(id: command.id, type: command.type, at: at, purpose: purpose, target: command.target,
      waiting: command.target != nil))
    if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
  }

  /// The command an error names; nil when the ID is not one of this call's.
  public mutating func failed(_ id: String?) -> Entry? {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
    entries[index].waiting = false
    return entries[index]
  }

  /// The append a confirmation answers; nil when none for that target waits.
  public mutating func confirmed(_ target: VoiceContextTarget) -> Entry? {
    guard let index = entries.firstIndex(where: { $0.waiting && $0.target == target }) else { return nil }
    entries[index].waiting = false
    return entries[index]
  }
}
