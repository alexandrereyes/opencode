import Foundation

public struct RevertBoundary: Codable, Sendable, Equatable {
  public let sessionID: String
  public let messageID: String
  public init(sessionID: String, messageID: String) {
    self.sessionID = sessionID
    self.messageID = messageID
  }
}

public struct SessionRevertState: Codable, Sendable, Hashable {
  public let messageID: String
  public init(messageID: String) { self.messageID = messageID }
}

public protocol SessionRevertActions: Sendable {
  func revertBoundaries(_ sessionID: String, cutoff: Double?, directory: String) async throws -> [RevertBoundary]
  func interrupt(_ sessionID: String, resume: Bool) async throws
  func waitForIdle(_ sessionID: String) async throws
  func stageRevert(_ boundary: RevertBoundary, files: Bool?) async throws
  func clearRevert(_ sessionID: String) async throws
  func inbox(_ sessionID: String) async throws -> [InboxItem]
  func cancelInbox(_ id: String, sessionID: String) async throws
}

public enum RevertProgress: Sendable, Equatable {
  case planning, descendants(completed: Int, total: Int), session, inbox
  public var label: String {
    switch self {
    case .planning: "Preparando para desfazer…"
    case .descendants(let completed, let total): "Atualizando subagentes · \(completed)/\(total)"
    case .session: "Atualizando a sessão…"
    case .inbox: "Atualizando a fila…"
    }
  }
}

public struct RevertResult: Sendable {
  public var succeeded = false
  public var failures: [String] = []
}

public enum SessionRevert {
  public static func users(_ messages: [ConversationMessage]) -> [ConversationMessage] {
    messages.filter { $0.type == "user" }
  }

  /// Hidden history starts at the boundary in server order, which loaded pages keep. IDs are not
  /// ordered: earlier iOS builds sent "msg_" + uppercase UUID, which sorts after the server's reply.
  public static func visible(_ messages: [ConversationMessage], boundary: String?) -> [ConversationMessage] {
    guard let boundary else { return messages }
    guard let index = messages.firstIndex(where: { $0.id == boundary }) else {
      return messages.filter { $0.id < boundary }
    }
    return Array(messages[..<index])
  }

  public static func undo(_ messages: [ConversationMessage], boundary: String?) -> ConversationMessage? {
    let users = users(messages)
    let index = boundary.flatMap { id in users.firstIndex { $0.id == id } } ?? users.count
    return index > 0 ? users[index - 1] : nil
  }

  public static func redo(_ messages: [ConversationMessage], boundary: String) -> ConversationMessage? {
    let users = users(messages)
    guard let index = users.firstIndex(where: { $0.id == boundary }), index + 1 < users.count else { return nil }
    return users[index + 1]
  }

  /// The family RPC plans only. Each descendant is staged without files, before the root.
  public static func perform(
    sessionID: String, target: ConversationMessage?, directory: String,
    active: Set<String>, pending: [InboxItem], using client: some SessionRevertActions,
    progress: @Sendable (RevertProgress) async -> Void = { _ in }
  ) async -> RevertResult {
    var result = RevertResult()
    await progress(.planning)
    let descendants: [RevertBoundary]
    do {
      descendants = try await client.revertBoundaries(sessionID, cutoff: target?.time.created, directory: directory)
    } catch {
      result.failures.append("Não foi possível consultar os subagentes: \(error.localizedDescription)")
      descendants = []
    }
    await progress(.descendants(completed: 0, total: descendants.count))
    for (index, boundary) in descendants.enumerated() {
      do {
        if active.contains(boundary.sessionID) {
          try await client.interrupt(boundary.sessionID, resume: false)
          try await client.waitForIdle(boundary.sessionID)
        }
        if target != nil { try await client.stageRevert(boundary, files: false) }
        else { try await client.clearRevert(boundary.sessionID) }
      } catch {
        result.failures.append("Subagente \(boundary.sessionID): \(error.localizedDescription)")
      }
      await progress(.descendants(completed: index + 1, total: descendants.count))
    }
    await progress(.session)
    do {
      if let target {
        try await client.interrupt(sessionID, resume: false)
        try await client.waitForIdle(sessionID)
        try await client.stageRevert(.init(sessionID: sessionID, messageID: target.id), files: nil)
        await progress(.inbox)
        let cutoff = Date().timeIntervalSince1970 * 1000
        let authoritative = (try? await client.inbox(sessionID)) ?? []
        let ids = Set(pending.filter { $0.type == "user" }.map(\.id)
          + authoritative.filter { $0.type == "user" && ($0.time?.created ?? 0) <= cutoff }.map(\.id))
        await withTaskGroup(of: Void.self) { group in
          for id in ids {
            group.addTask { try? await client.cancelInbox(id, sessionID: sessionID) }
          }
        }
      } else {
        try await client.clearRevert(sessionID)
      }
      result.succeeded = true
    } catch {
      result.failures.append("Sessão: \(error.localizedDescription)")
    }
    return result
  }
}

extension OpenCodeClient: SessionRevertActions {
  #if DEBUG
  public static func revertFailureFixture(configuration: ServerConfiguration, sessionID: String) -> Self {
    precondition(configuration.isolatedTestSandbox)
    return Self(configuration: configuration) { request in
      if request.httpMethod == "POST", request.url?.path == "/api/session/\(sessionID)/revert/stage" {
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
      }
      return try await URLSession.shared.data(for: request)
    }
  }
  #endif
  public func revertBoundaries(_ sessionID: String, cutoff: Double?, directory: String) async throws -> [RevertBoundary] {
    struct Input: Encodable { let sessionID: String; let cutoff: Double? }
    return try await rpc("custom.session-family", cutoff == nil ? "clear" : "revert",
      input: Input(sessionID: sessionID, cutoff: cutoff), directory: directory)
  }
  public func waitForIdle(_ sessionID: String) async throws {
    try await perform("POST", "/api/experimental/session/\(sessionID)/wait")
  }
  public func stageRevert(_ boundary: RevertBoundary, files: Bool?) async throws {
    struct Input: Encodable { let messageID: String; let files: Bool? }
    try await post("/api/session/\(boundary.sessionID)/revert/stage", input: Input(messageID: boundary.messageID, files: files))
  }
  public func clearRevert(_ sessionID: String) async throws {
    try await perform("DELETE", "/api/session/\(sessionID)/revert")
  }
  public func commitRevert(_ sessionID: String) async throws {
    try await perform("POST", "/api/session/\(sessionID)/revert/commit")
  }
}
