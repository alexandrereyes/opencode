import Foundation
import Testing
@testable import OpenCodeKit

struct LiveActivityRelevanceTests {
  @Test func voiceOutranksLocalAndPushedAgents() throws {
    #expect(LiveActivityRelevance.voice > LiveActivityRelevance.agents)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../../../plugin-app-custom/docs/live-activity")
    for event in ["start", "update", "end"] {
      let data = try Data(contentsOf: root.appendingPathComponent("push-\(event).json"))
      let payload = try JSONDecoder().decode(Payload.self, from: data)
      #expect(payload.aps.relevance == LiveActivityRelevance.agents)
    }
  }

  private struct Payload: Decodable {
    let aps: APS
    struct APS: Decodable {
      let relevance: Double
      enum CodingKeys: String, CodingKey { case relevance = "relevance-score" }
    }
  }
}
