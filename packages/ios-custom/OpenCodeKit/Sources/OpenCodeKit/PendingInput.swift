import Foundation

/// Where an undelivered user prompt stands relative to the runner, as in the web client's
/// `DataPendingStatus`: `starting` is promoted at the next idle boundary, `steering` waits for the
/// next step boundary of an execution that already delivered input, `stranded` outlived an
/// execution that ended without delivering it, and `queued` waits in the queue tray.
public enum PendingInputStatus: Sendable, Equatable {
  case starting, steering, stranded, queued

  /// A pending steer offers its queue and delete actions until the server delivers it.
  public var actions: Bool { self != .queued }
  /// It reads as waiting, with its own label and color, only behind delivered work or after an
  /// execution ended without it.
  public var waiting: Bool { self == .steering || self == .stranded }
}

public enum PendingInputs {
  /// Undelivered user steers shown below the transcript in admission order. Queued items stay in
  /// the tray; an item whose message already arrived is delivered.
  public static func steers(_ inbox: [InboxItem], messages: [ConversationMessage]) -> [InboxItem] {
    let delivered = Set(messages.map(\.id))
    return inbox.filter { $0.type == "user" && $0.delivery == .steer && !delivered.contains($0.id) }
  }

  public static func status(
    _ item: InboxItem, inbox: [InboxItem], messages: [ConversationMessage], running: Bool
  ) -> PendingInputStatus? {
    guard item.type == "user" else { return nil }
    if item.delivery == .queue { return .queued }
    let boundary = messages.lastIndex { $0.type == .idle }
    if !running {
      guard let boundary, let created = item.time?.created else { return .starting }
      return created <= messages[boundary].time.created ? .stranded : .starting
    }
    // An execution's idle boundary promotes every pending steer at once, so a steer only waits
    // behind work once the current execution has delivered input.
    let pending = Set(inbox.map(\.id))
    let delivered = messages[(boundary.map { $0 + 1 } ?? 0)...].contains {
      $0.type == .user && !pending.contains($0.id)
    }
    return delivered ? .steering : .starting
  }
}

extension InboxItem {
  /// The client-side row rendered before admission, like the web's optimistic admission. The
  /// server echo upserts the same ID. Staged attachments render by name until their paths exist.
  public init(optimistic request: PromptRequest, sessionID: String, attachments: [String], created: Double) {
    var metadata = request.metadata
    if !attachments.isEmpty { metadata["attachments"] = .array(attachments.map { .object(["name": .string($0)]) }) }
    self.init(
      id: request.id, sessionID: sessionID, type: "user", delivery: request.delivery,
      payload: Payload(text: request.text, metadata: metadata, files: request.files, agents: request.agents,
        skills: request.skills),
      time: MessageTime(created: created))
  }

  /// The undelivered prompt rendered as the user message the server will project on delivery.
  public var message: ConversationMessage {
    var message = ConversationMessage(id: id, type: "user", time: time ?? MessageTime(created: 0))
    message.text = payload.text
    message.metadata = payload.metadata
    message.files = payload.files
    message.agents = payload.agents
    message.skills = payload.skills
    return message
  }
}
