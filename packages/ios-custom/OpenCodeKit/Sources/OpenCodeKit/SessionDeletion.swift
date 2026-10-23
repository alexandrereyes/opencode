import Foundation

public struct SessionDeletionPlan: Sendable {
  public let sessionID: String
  public let ids: Set<String>

  public init(sessionID: String, sessions: [Session]) {
    self.sessionID = sessionID
    var ids: Set<String> = [sessionID]
    var previous = 0
    while previous != ids.count {
      previous = ids.count
      for session in sessions where session.parentID.map(ids.contains) == true {
        ids.insert(session.id)
      }
    }
    self.ids = ids
  }

  public func preferenceCleanup(_ preferences: Preferences) -> [PreferenceIntent] {
    let pins = preferences.data.pinnedSessions.filter { key in
      SessionPreferenceKey.sessionID(key).map(ids.contains) == true
    }.map { PreferenceIntent.pin(session: $0, pinned: false) }
    let mutes = (preferences.data.mutedSessions ?? []).filter { key in
      SessionPreferenceKey.sessionID(key).map(ids.contains) == true
    }.map { PreferenceIntent.mute(session: $0, muted: false) }
    return pins + mutes
  }

  public static func confirmation(_ title: String) -> String {
    "Excluir sessão \"\(title)\" e todas as suas sessões filhas? Isso exclui permanentemente suas mensagens e não pode ser desfeito."
  }
}

extension OpenCodeClient {
  #if DEBUG
  public static func deletionFailureFixture(configuration: ServerConfiguration, sessionID: String) -> Self {
    precondition(configuration.url.absoluteString == "http://127.0.0.1:4177")
    return Self(configuration: configuration) { request in
      if request.httpMethod == "DELETE", request.url?.path == "/api/session/\(sessionID)" {
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
      }
      return try await URLSession.shared.data(for: request)
    }
  }
  #endif

  public func deletionPlan(_ sessionID: String) async throws -> SessionDeletionPlan {
    var sessions: [Session] = []
    var after: String?
    repeat {
      let page = try await familyPage(sessionID, after: after)
      sessions += page.data
      if page.next == after { break }
      after = page.next
    } while after != nil
    return SessionDeletionPlan(sessionID: sessionID, sessions: sessions)
  }

  public func deleteSession(_ sessionID: String) async throws {
    // The server interrupts and removes descendants before their parent.
    try await perform("DELETE", "/api/session/\(sessionID)")
  }
}
