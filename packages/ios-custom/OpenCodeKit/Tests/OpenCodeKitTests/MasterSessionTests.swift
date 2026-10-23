import Foundation
import Testing

@testable import OpenCodeKit

@Test func masterPreferencesRemainBackwardCompatibleAndIntentsUseServerProfile() throws {
  let old = try JSONDecoder().decode(Preferences.self, from: Data("""
    {"revision":1,"data":{"projects":{},"pinnedSessions":[],"settings":{"autoApprove":false}}}
    """.utf8))
  #expect(old.data.masterSessions == nil)
  for (intent, expected) in [
    (PreferenceIntent.masterSet("ses_master"), "master.set"), (.masterClear, "master.clear"),
  ] {
    let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(intent))
    #expect(value.object?["type"]?.string == expected)
    #expect(value.object?["server"]?.string == "local")
    #expect(value.object?["sessionID"]?.string == (expected == "master.set" ? "ses_master" : nil))
  }
}

@Test func masterOriginIsUserOnlyAndUnknownMetadataStaysUnmarked() {
  var message = ConversationMessage(id: "msg_test", type: "user", time: MessageTime(created: 1))
  message.metadata = ["custom.master": .object(["sessionID": .string("ses_master")])]
  #expect(message.masterOrigin == "ses_master")
  message.type = .init("assistant")
  #expect(message.masterOrigin == nil)
  message.type = .init("user")
  message.metadata = ["custom.master": .bool(true)]
  #expect(message.masterOrigin == nil)
}

@Test func masterCapabilityDistinguishesOldServerFromConnectivityAndAuth() async throws {
  for (status, body, expected) in [
    (400, #"{"_tag":"RpcError","type":"rpc.unavailable"}"#, MasterAvailability.unsupported),
    (404, "not found", .unsupported), (401, "unauthorized", .unavailable),
    (503, "unavailable", .unavailable),
  ] {
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4179")!)) { request in
      #expect(request.url?.path == "/api/rpc/custom.master/info")
      #expect(request.httpMethod == "POST")
      return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    do {
      _ = try await client.masterInfo()
      Issue.record("Expected unsupported or unavailable capability")
    } catch { #expect(MasterAvailability.classify(error) == expected) }
  }
  let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4179")!)) { request in
    let body = #"{"output":{"version":1,"agent":"mestra","model":{"providerID":"llm-proxy","id":"gpt-6.1-sol-ultrafast","variant":"medium"}}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  let info = try await client.masterInfo()
  #expect(info.agent == "mestra")
  #expect(info.model?.variant == "medium")
  #expect(MasterAvailability.unsupported.label == "Atualize o servidor para usar a Sessão mestra")
}

@Test func masterChatLifecycleUsesExistingTypedAllocationRPCs() async throws {
  let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4179")!)) { request in
    let input = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
    let method = request.url!.lastPathComponent
    #expect(request.url!.path.hasPrefix("/api/rpc/custom.chats/"))
    if method != "allocate" {
      #expect(input.object?["input"]?.object?["sessionID"]?.string == "ses_master")
      #expect(input.object?["input"]?.object?["directory"]?.string == "/chats/owned")
    }
    let body = method == "allocate" ? #"{"output":{"id":"allocation","directory":"/chats/owned"}}"# : #"{"output":{}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  let allocation = try await client.allocateChat()
  try await client.claimChat(allocation, sessionID: "ses_master")
  try await client.claimChat(allocation, sessionID: "ses_master", confirm: true)
}
