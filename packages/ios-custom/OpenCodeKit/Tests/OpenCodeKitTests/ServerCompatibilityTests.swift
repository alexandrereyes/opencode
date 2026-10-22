import Foundation
import Testing

@testable import OpenCodeKit

private actor TranscriptProbe {
  var requests: [URLRequest] = []
  let status: Int
  let body: String
  let nativeStatus: Int
  init(status: Int, body: String, nativeStatus: Int = 200) {
    self.status = status
    self.body = body
    self.nativeStatus = nativeStatus
  }
  func respond(_ request: URLRequest) -> (Data, URLResponse) {
    requests.append(request)
    let rpc = request.url?.path == "/api/rpc/custom.transcript/list"
    #expect(rpc || request.url?.path == "/api/session/ses_test/message")
    #expect(request.httpMethod == (rpc ? "POST" : "GET"))
    let page = """
      {"data":[{"id":"msg_latest","type":"assistant","time":{"created":2},
      "content":[{"type":"tool","id":"tool_test","name":"read","state":{"status":"completed",
      "input":{"path":"image.png"},"content":[{"type":"file","mime":"image/png","uri":"data:image/png;base64,YQ=="}]}}]},
      {"id":"msg_first","type":"user","time":{"created":1},"text":"Olá"}],
      "cursor":{"previous":"previous","next":"opaque_next"}}
      """
    return (Data((rpc ? body : page).utf8), HTTPURLResponse(
      url: request.url!, statusCode: rpc ? status : nativeStatus, httpVersion: nil, headerFields: nil)!)
  }
}

#if DEBUG
@Test func debugNativeTranscriptBypassesRPCForTailHistoryAndPreview() async throws {
  let probe = TranscriptProbe(status: 500, body: "RPC must not be called")
  var client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) {
    await probe.respond($0)
  }
  client.usesNativeTranscript = true
  #expect(try await client.conversation("ses_test").data.count == 2)
  _ = try await client.conversation("ses_test", cursor: "opaque_next")
  #expect(try await client.preview("ses_test").image)
  let requests = await probe.requests
  #expect(requests.count == 3)
  #expect(requests.allSatisfy { $0.httpMethod == "GET" })
}
#endif

@Test(arguments: [
  #"{"data":[],"cursor":{"previous":null,"next":null}}"#,
  #"{"data":[],"cursor":{}}"#,
]) func emptyNativeAndRPCCursorLinksBothDecodeAsEndOfHistory(_ body: String) throws {
  let page = try JSONDecoder().decode(ConversationPage.self, from: Data(body.utf8))
  #expect(page.data.isEmpty)
  #expect(page.cursor?.next == nil)
  #expect(page.cursor?.previous == nil)
}

@Test func olderServerFallsBackForConversationHistoryAndSessionPreviews() async throws {
  // 1de0005 predates the custom.transcript registration; Rpc.call emits this error.
  let probe = TranscriptProbe(status: 400, body:
    #"{"_tag":"RpcError","type":"rpc.unavailable","message":"RPC is unavailable: custom.transcript"}"#)
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!, password: "test")) {
    await probe.respond($0)
  }
  let page = try await client.conversation("ses_test")
  #expect(page.data.map(\.id) == ["msg_latest", "msg_first"])
  #expect(page.cursor?.next == "opaque_next")
  #expect(page.data.first?.tools.first?.state?.object?["content"]?.array?.first?.object?["uri"]?.string == "data:image/png;base64,YQ==")
  let cursor = "opaque_=&/next"
  _ = try await client.conversation("ses_test", cursor: cursor)
  #expect(try await client.preview("ses_test").image)
  let requests = await probe.requests
  #expect(requests.count == 6)
  for (index, limit) in [(0, 40), (2, 40), (4, 3)] {
    let input = try JSONDecoder().decode(JSONValue.self, from: requests[index].httpBody!).object?["input"]?.object
    #expect(input?["sessionID"]?.string == "ses_test")
    #expect(input?["limit"]?.number == Double(limit))
    #expect(input?["order"]?.string == (index == 2 ? nil : "desc"))
    #expect(input?["cursor"]?.string == (index == 2 ? cursor : nil))
    let query = URLComponents(url: requests[index + 1].url!, resolvingAgainstBaseURL: false)?.queryItems
    #expect(query?.first { $0.name == "limit" }?.value == String(limit))
    #expect(query?.first { $0.name == "order" }?.value == (index == 2 ? nil : "desc"))
    #expect(query?.first { $0.name == "cursor" }?.value == (index == 2 ? cursor : nil))
    #expect(requests[index + 1].httpBody == nil)
    #expect(requests[index + 1].value(forHTTPHeaderField: "Authorization") == "Basic " + Data("opencode:test".utf8).base64EncodedString())
  }
}

@Test func newerServerKeepsLeanRPCWithoutAnExtraRequest() async throws {
  let probe = TranscriptProbe(status: 200, body:
    #"{"output":{"data":[{"id":"msg_lean","type":"user","text":"Olá","time":{"created":1}}],"cursor":{"next":"opaque"}}}"#)
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) {
    await probe.respond($0)
  }
  #expect(try await client.conversation("ses_test").data.first?.id == "msg_lean")
  #expect(try await client.preview("ses_test").text == "Você: Olá")
  #expect(await probe.requests.count == 2)
}

@Test(arguments: [
  (400, #"{"_tag":"RpcError","type":"read_failed","message":"Unable to read session messages"}"#),
  (503, "unavailable"), (200, #"{"output":{}}"#),
]) func transcriptOptimizationFailureStillReadsCanonicalEndpoint(status: Int, body: String) async throws {
  let probe = TranscriptProbe(status: status, body: body)
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) {
    await probe.respond($0)
  }
  #expect(try await client.conversation("ses_test").data.count == 2)
  #expect(await probe.requests.count == 2)
}

@Test func transcriptFallbackPreservesCanonicalFailureAndCancellation() async throws {
  let probe = TranscriptProbe(status: 400, body: #"{"_tag":"RpcError","type":"rpc.unavailable"}"#, nativeStatus: 404)
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) {
    await probe.respond($0)
  }
  do {
    _ = try await client.conversation("ses_test")
    Issue.record("A falha do endpoint nativo deve ser preservada")
  } catch ClientError.http(let status) {
    #expect(status == 404)
  }
  for error in [URLError(.cancelled) as any Error, CancellationError()] {
    let cancelled = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
      #expect(request.httpMethod == "POST")
      throw error
    }
    do {
      _ = try await cancelled.conversation("ses_test")
      Issue.record("Uma leitura cancelada não deve iniciar o fallback")
    } catch let caught as URLError {
      #expect(caught.code == .cancelled)
    } catch {
      #expect(error is CancellationError)
    }
  }
}

@Test func olderPreferencesDecodeAndUnsupportedMuteExplainsRequiredUpdate() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    let mutation = request.url?.path.hasSuffix("/mutate") == true
    let body = mutation
      ? #"{"_tag":"RpcError","type":"rpc.invalid_input","message":"Invalid RPC input"}"#
      : #"{"output":{"revision":1,"data":{"projects":{},"pinnedSessions":[],"settings":{"autoApprove":false}}}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: mutation ? 400 : 200, httpVersion: nil, headerFields: nil)!)
  }
  #expect(try await client.preferences().data.mutedSessions == nil)
  do {
    _ = try await client.mutate(.mute(session: "ses_test", muted: true))
    Issue.record("Silenciar não pode aparentar sucesso em um servidor antigo")
  } catch ClientError.operation(let message) {
    #expect(message.contains("Atualize o servidor"))
  }
  do {
    _ = try await client.mutate(.pin(session: "ses_test", pinned: true))
    Issue.record("Outras falhas não devem ser classificadas como recurso ausente")
  } catch ClientError.rpc(let type) {
    #expect(type == "rpc.invalid_input")
  }
}

@Test func optionalMuteFieldDoesNotDisableNewerServerMutations() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    #expect(request.url?.path == "/api/rpc/custom.preferences/mutate")
    let input = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!).object?["input"]?.object
    #expect(input?["type"]?.string == "sidebar.mute")
    #expect(input?["muted"] == .bool(true))
    let body = #"{"output":{"revision":2,"data":{"projects":{},"pinnedSessions":[],"mutedSessions":["ses_test"],"settings":{"autoApprove":false}}}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  #expect(try await client.mutate(.mute(session: "ses_test", muted: true)).data.mutedSessions == ["ses_test"])
}
