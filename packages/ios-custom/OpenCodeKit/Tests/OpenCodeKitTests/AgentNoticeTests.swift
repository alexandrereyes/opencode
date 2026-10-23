import Foundation
import Testing

@testable import OpenCodeKit

@Test(arguments: ["build", "plan"])
func historicalAgentNoticesFollowWebVisibility(_ previous: String) throws {
  let message = try JSONDecoder().decode(ConversationMessage.self, from: Data("""
    {"id":"msg_switch","type":"agent-switched","agent":"build","previous":"\(previous)","time":{"created":1}}
    """.utf8))
  #expect(message.notice == "Agente alterado para build")
  #expect(!ConversationActivity.project([message]).messages.flatMap(\.rows).isEmpty)
}
