import Foundation
import Testing

@testable import OpenCodeKit

private struct RPC<Value: Decodable>: Decodable { let output: Value }
private struct SessionsPage: Decodable { let data: [Session] }

private func fixture<Value: Decodable>(_ name: String, as type: Value.Type) throws -> Value {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
  return try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

@Test func liveNavigationAndPreferences() throws {
  let navigation = try fixture("navigation", as: RPC<NavigationPage>.self).output
  #expect(!navigation.data.isEmpty)
  #expect(navigation.data.contains { $0.permissionAt != nil })
  #expect(navigation.data.contains { $0.questionAt != nil })
  let preferences = try fixture("preferences", as: RPC<Preferences>.self).output
  #expect(preferences.data.projects["local"]?.projects.count == 3)
  #expect(preferences.data.notifySessions?.isEmpty == false)
  #expect(preferences.data.pinnedSessions.allSatisfy { SessionPreferenceKey.sessionID($0) != nil })
}

@Test func liveRequestsAndInventory() throws {
  let permissions = try fixture("permissions", as: RPC<[PermissionRequest]>.self).output
  #expect(permissions.first?.preview.contains("git push") == true)
  let forms = try fixture("forms", as: DataResponse<[PendingForm]>.self).data
  #expect(forms.first?.preview == "Qual opção você prefere?")
  #expect(try fixture("projects", as: [Project].self).count >= 3)
  #expect(
    try fixture("active", as: DataResponse<[String: ActiveState]>.self).data.values.contains {
      $0.isRunning
    })
  #expect(
    try fixture("sessions", as: SessionsPage.self).data.filter { $0.time.archived != nil }.count
      == 12)
}

@Test func liveTranscriptsNeverNeedInlineMedia() throws {
  let running = try fixture("transcript-running", as: RPC<TranscriptPage>.self).output
  #expect(SessionPreview(messages: running.data).activity?.contains("bun test") == true)
  let image = try fixture("transcript-image", as: RPC<TranscriptPage>.self).output
  #expect(SessionPreview(messages: image.data).image)
  let user = try fixture("transcript-user", as: RPC<TranscriptPage>.self).output
  #expect(SessionPreview(messages: user.data).text.hasPrefix("Você: "))
  #expect(
    try fixture("subscriptions", as: RPC<Subscriptions>.self).output.accounts.isEmpty == false)
}
