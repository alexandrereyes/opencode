import Foundation

/// The AI review of a dictation, `custom.dictation` in `plugin-app-custom`: after the device transcribes, the server
/// fixes spelling, punctuation and misheard words. It gives up after 5 s without a new streamed piece and then
/// returns the transcription, so a failure of any kind inserts the raw text, with no error shown.
public enum DictationReview {
  /// The app's own limit, for a server that never answers; a long reply that keeps streaming stays under it.
  public static let ceiling: TimeInterval = 60
  /// The RPC's limit for the transcription and for the context.
  public static let maxCharacters = 20_000
  /// The end of each recent message and how many of them the context keeps.
  static let messageCharacters = 1_500
  static let messageCount = 6

  public struct Turn: Sendable, Equatable {
    public enum Role: String, Sendable { case user = "User", assistant = "Assistant" }
    public let role: Role
    public let text: String
    public init(_ role: Role, _ text: String) { self.role = role; self.text = text }
  }

  /// The visible text of the latest user and assistant messages, oldest first.
  public static func turns(_ messages: [ConversationMessage]) -> [Turn] {
    let turns = messages.compactMap { message -> Turn? in
      let text: String? = switch message.type {
      case .user: message.text
      case .assistant: message.content?.filter { $0.type == .text }.compactMap(\.text).joined(separator: "\n\n")
      default: nil
      }
      guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
      return Turn(message.type == .user ? .user : .assistant, text)
    }
    return Array(turns.suffix(messageCount))
  }

  /// A side-question thread (Pergunta paralela), oldest first.
  public static func turns(_ entries: [SideQuestionEntry]) -> [Turn] {
    let turns = entries.flatMap { [Turn(.user, $0.question), Turn(.assistant, $0.answer)] }
      .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return Array(turns.suffix(messageCount))
  }

  /// What the composer shows, as it is: the passage being commented, the end of the latest messages and the
  /// draft. Nil when there is nothing.
  public static func context(draft: String, quote: String? = nil, turns: [Turn] = []) -> String? {
    let quote = quote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = (quote.isEmpty ? [] : ["Quoted passage:\n" + String(quote.prefix(4_000))])
      + turns.map { "\($0.role.rawValue): " + String($0.text.suffix(messageCharacters)) }
      + (draft.isEmpty ? [] : ["Draft:\n" + String(draft.suffix(4_000))])
    guard !parts.isEmpty else { return nil }
    return String(parts.joined(separator: "\n\n").suffix(maxCharacters))
  }

  /// The draft's edits for one transcription, each its own undo step: the raw text, then the revision if it
  /// differs, so the first undo brings the raw text back and the second removes it.
  public static func edits(raw: String, revised: String?) -> [String] {
    guard let revised, !revised.isEmpty, revised != raw else { return [raw] }
    return [raw, revised]
  }
}

/// One recording's review switch (the sparkles in the recording bar, ⌥⌘E on the Mac) and the review under way.
/// Every recording starts with it on; nothing carries over to the next one.
public struct DictationRevision: Sendable, Equatable {
  public private(set) var enabled = true
  /// The transcription waiting for its review ("Ajustando texto…").
  public private(set) var reviewing: String?
  public init() {}

  /// A new recording.
  public mutating func begin() { self = DictationRevision() }

  /// The switch. During the review it means Usar original and returns the raw text to insert now.
  public mutating func toggle() -> String? {
    if reviewing != nil { return useOriginal() }
    enabled.toggle()
    return nil
  }

  /// The transcription is ready: whether to ask for its review.
  public mutating func transcribed(_ text: String, reviewer: Bool) -> Bool {
    guard enabled, reviewer else { return false }
    reviewing = text
    return true
  }

  /// Usar original: the raw text at once; the reply, when it comes, is ignored.
  public mutating func useOriginal() -> String? {
    defer { reviewing = nil }
    return reviewing
  }

  /// The reply arrived (nil: failed, timed out or unchanged). The edits to make, or nil when the review was left.
  public mutating func reviewed(_ raw: String, revised: String?) -> [String]? {
    guard reviewing == raw else { return nil }
    reviewing = nil
    return DictationReview.edits(raw: raw, revised: revised)
  }

  /// Esc or Descartar: nothing is inserted.
  public mutating func cancel() { reviewing = nil }
}

extension OpenCodeClient {
  /// The revised text, or nil when the server kept the transcription, failed, timed out or lacks the RPC.
  public func reviewDictation(_ text: String, context: String?) async -> String? {
    struct Input: Encodable { let text: String; let context: String? }
    struct Output: Decodable { let text: String; let revised: Bool }
    let input = Input(text: String(text.prefix(DictationReview.maxCharacters)), context: context)
    guard let output: Output = try? await rpc("custom.dictation", "review", input: input, timeout: DictationReview.ceiling),
      output.revised else { return nil }
    return output.text
  }
}
