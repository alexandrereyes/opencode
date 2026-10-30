import Foundation
import Synchronization

public enum PromptDelivery: String, Codable, Sendable {
  case steer, queue
  public static func choose(busy: Bool, preference: Self, alternate: Bool = false) -> Self {
    guard busy else { return .steer }
    return alternate ? (preference == .steer ? .queue : .steer) : preference
  }
}

public struct InboxItem: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let sessionID: String
  public let type: String
  public let delivery: PromptDelivery
  public let payload: Payload
  public var time: MessageTime?
  public struct Payload: Codable, Sendable, Equatable {
    public let text: String?
    public let metadata: [String: JSONValue]?
    public let files: [JSONValue]?
    public let agents: [JSONValue]?
    public let skills: [JSONValue]?
    public var displayText: String { metadata?["displayText"]?.string ?? text ?? "" }
  }
  public var queuedUser: Bool { type == "user" && delivery == .queue }
}

public struct PromptRequest: Codable, Sendable, Equatable {
  /// The server and web `SessionMessage.ID.create()` shape: ascending hex time, then base62.
  /// Clients order and hide history by comparing these IDs.
  public static func newID(now: Date = .now) -> String {
    let millis = UInt64(now.timeIntervalSince1970 * 1000)
    let counter = idClock.withLock { clock in
      clock = clock.millis == millis ? (millis, clock.counter + 1) : (millis, 1)
      return clock.counter
    }
    let time = String((millis &* 0x1000 &+ counter) & 0xFFFF_FFFF_FFFF, radix: 16)
    let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    return "msg_" + String(repeating: "0", count: 12 - time.count) + time
      + String((0..<14).map { _ in chars[Int.random(in: 0..<62)] })
  }
  private static let idClock = Mutex<(millis: UInt64, counter: UInt64)>((0, 0))
  public let id: String
  public let text: String
  public let delivery: PromptDelivery
  public let metadata: [String: JSONValue]
  public let files: [JSONValue]?
  public let agents: [JSONValue]?
  public let skills: [JSONValue]?
  init(
    id: String, text: String, delivery: PromptDelivery, metadata: [String: JSONValue],
    files: [JSONValue], agents: [JSONValue], skills: [JSONValue]
  ) {
    self.id = id
    self.text = text
    self.delivery = delivery
    self.metadata = metadata
    self.files = files.isEmpty ? nil : files
    self.agents = agents.isEmpty ? nil : agents
    self.skills = skills.isEmpty ? nil : skills
  }
  public init(
    id: String = PromptRequest.newID(), text: String,
    delivery: PromptDelivery, agent: String, model: ModelReference,
    restoring: InboxItem.Payload? = nil
  ) {
    self.id = id
    self.text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\r", with: "\n")
    self.delivery = delivery
    var metadata = restoring?.metadata ?? [:]
    metadata["displayText"] = .string(self.text)
    metadata["comments"] = metadata["comments"] ?? .array([])
    metadata["agent"] = .string(agent)
    var reference: [String: JSONValue] = [
      "providerID": .string(model.providerID), "modelID": .string(model.id),
    ]
    if let variant = model.variant { reference["variant"] = .string(variant) }
    metadata["model"] = .object(reference)
    self.metadata = metadata
    files = restoring?.files
    agents = restoring?.agents
    skills = restoring?.skills
  }
}

public protocol ConversationActions: Sendable {
  func session(_ id: String) async throws -> Session
  func selectAgent(_ agent: String, sessionID: String) async throws
  func selectModel(_ model: ModelReference, sessionID: String) async throws
  func prompt(_ request: PromptRequest, sessionID: String) async throws
  func cancelInbox(_ id: String, sessionID: String) async throws
  func commitRevert(_ sessionID: String) async throws
}

extension ConversationActions {
  public func commitRevert(_ sessionID: String) async throws {
    throw ClientError.operation("Este cliente não permite confirmar uma reversão.")
  }
}

public struct PromptSubmission: Sendable {
  public let request: PromptRequest
  public let sessionID: String
  public let agent: String
  public let model: ModelReference
  public let replacing: String?
  public let keepsAgent: Bool
  public let commitsRevert: Bool
  public init(
    request: PromptRequest, sessionID: String, agent: String, model: ModelReference,
    replacing: String? = nil, keepsAgent: Bool = false, commitsRevert: Bool = false
  ) {
    self.request = request
    self.sessionID = sessionID
    self.agent = agent
    self.model = model
    self.replacing = replacing
    self.keepsAgent = keepsAgent
    self.commitsRevert = commitsRevert
  }
  public func send(using actions: some ConversationActions) async throws {
    try await applySelection(using: actions)
    do { try await actions.prompt(request, sessionID: sessionID) } catch {
      // Only admission is idempotent. A lost response retries this exact request ID.
      guard Self.ambiguous(error), !Task.isCancelled else { throw error }
      try await actions.prompt(request, sessionID: sessionID)
    }
    if let replacing { try await actions.cancelInbox(replacing, sessionID: sessionID) }
  }
  public func applySelection(using actions: some ConversationActions) async throws {
    guard request.delivery == .steer else {
      if commitsRevert { try await actions.commitRevert(sessionID) }
      return
    }
    if !keepsAgent {
      // Agent switches are not deduplicated by the server; read past any delayed SSE update.
      let current = try await actions.session(sessionID)
      if current.agent != agent { try await actions.selectAgent(agent, sessionID: sessionID) }
    }
    if commitsRevert { try await actions.commitRevert(sessionID) }
    // Commit before the model switch, which would otherwise be removed with the old history.
    // Like the web, let the server deduplicate model/variant selection.
    try await actions.selectModel(model, sessionID: sessionID)
  }
  private static func ambiguous(_ error: any Error) -> Bool {
    if let error = error as? URLError { return error.code != .cancelled }
    if case ClientError.http(let status) = error { return status >= 500 }
    return false
  }
}

public struct PermissionReply: Codable, Sendable {
  public enum Decision: String, Codable, Sendable { case once, always, reject }
  public let decision: Decision
  public init(_ decision: Decision) { self.decision = decision }
}

public struct QuestionReply: Codable, Sendable {
  public let answer: [String: JSONValue]
  public init(form: PendingForm, values: [String: JSONValue]) {
    var active: [String: JSONValue] = [:]
    for field in form.fields where Self.visible(field, values: active) {
      guard let value = values[field.key], value != .string(""), value != .array([]) else {
        continue
      }
      active[field.key] = value
    }
    answer = active
  }
  public static func visible(_ field: PendingForm.Field, values: [String: JSONValue]) -> Bool {
    guard field.hidden != true else { return false }
    return (field.when ?? []).allSatisfy { condition in
      guard let answer = values[condition.key] else { return false }
      let matches = answer.array.map { $0.contains(condition.value) } ?? (answer == condition.value)
      return condition.op == "eq" ? matches : condition.op == "neq" && !matches
    }
  }
  public func valid(for form: PendingForm) -> Bool {
    form.fields.filter { Self.visible($0, values: answer) }.allSatisfy { field in
      guard let value = answer[field.key] else { return field.required != true }
      if field.type == .string {
        guard let text = value.string else { return false }
        return field.custom == true || field.options == nil
          || field.options?.contains { $0.value == text } == true
      }
      if field.type == .multiselect {
        guard let values = value.array, values.count >= (field.minItems ?? 0),
          values.count <= (field.maxItems ?? Int.max)
        else { return false }
        return values.allSatisfy { value in
          value.string != nil
            && (field.custom == true
              || field.options?.contains { .string($0.value) == value } == true)
        }
      }
      return false
    }
  }

  /// Return in a question's own answer. The form has one way to send, its Enviar: Return is the same once every
  /// question shown is answered; before that it goes to the next unanswered one after this field (then from the top).
  public func onReturn(in form: PendingForm, from key: String) -> QuestionReturn {
    let fields = form.fields.filter { Self.visible($0, values: answer) }
    let index = fields.firstIndex { $0.key == key }.map { $0 + 1 } ?? 0
    if let next = (fields[index...] + fields[..<index]).first(where: { answer[$0.key] == nil }) {
      return next.key == key ? .stay : .next(next.key)
    }
    return valid(for: form) ? .send : .stay
  }
}

public enum QuestionReturn: Equatable, Sendable {
  /// Every question is answered: the same as Enviar.
  case send
  /// The question to go to.
  case next(String)
  /// This question is the one left (still empty), or an answer is not valid yet (Enviar is off too).
  case stay
}

extension OpenCodeClient: ConversationActions {
  public func inbox(_ sessionID: String) async throws -> [InboxItem] {
    let response: DataResponse<[InboxItem]> = try await get("/api/session/\(sessionID)/inbox")
    return response.data
  }
  public func selectAgent(_ agent: String, sessionID: String) async throws {
    struct Input: Encodable { let agent: String }
    try await post("/api/session/\(sessionID)/agent", input: Input(agent: agent))
  }
  public func selectModel(_ model: ModelReference, sessionID: String) async throws {
    struct Input: Encodable { let model: ModelReference }
    try await post("/api/session/\(sessionID)/model", input: Input(model: model))
  }
  public func prompt(_ request: PromptRequest, sessionID: String) async throws {
    try await post("/api/session/\(sessionID)/prompt", input: request)
  }
  public func cancelInbox(_ id: String, sessionID: String) async throws {
    try await perform("DELETE", "/api/session/\(sessionID)/inbox/\(id)")
  }
  public func promoteInbox(_ id: String, sessionID: String) async throws {
    try await updateInbox(id, sessionID: sessionID, delivery: .steer)
  }
  public func updateInbox(_ id: String, sessionID: String, delivery: PromptDelivery) async throws {
    struct Input: Encodable { let delivery: PromptDelivery }
    try await perform(
      "PATCH", "/api/session/\(sessionID)/inbox/\(id)",
      body: JSONEncoder().encode(Input(delivery: delivery)))
  }
  public func interrupt(_ sessionID: String, resume: Bool = false) async throws {
    try await perform(
      "POST", "/api/session/\(sessionID)/interrupt",
      query: resume ? [URLQueryItem(name: "resume", value: "true")] : [])
  }
  public func background(_ sessionID: String) async throws {
    try await perform("POST", "/api/session/\(sessionID)/background")
  }
  public func stopShell(_ id: String, directory: String) async throws {
    try await perform(
      "DELETE", "/api/shell/\(id)",
      query: [URLQueryItem(name: "location[directory]", value: directory)])
  }
  public func reply(_ permission: PermissionRequest, decision: PermissionReply.Decision)
    async throws
  {
    try await post(
      "/api/session/\(permission.sessionID)/permission/\(permission.id)/reply",
      input: PermissionReply(decision))
  }
  public func reply(_ form: PendingForm, answer: QuestionReply) async throws {
    try await post("/api/session/\(form.sessionID)/form/\(form.id)/reply", input: answer)
  }
  public func dismiss(_ form: PendingForm) async throws {
    try await perform("DELETE", "/api/session/\(form.sessionID)/form/\(form.id)")
  }
}
