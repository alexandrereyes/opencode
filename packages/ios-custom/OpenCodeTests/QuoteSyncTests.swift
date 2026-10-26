import Foundation
import Synchronization
import XCTest

@testable import OpenCode
@testable import OpenCodeKit

/// Server mode against a recording `custom.quotes` stand-in: undo and queued-prompt edits.
@MainActor final class QuoteSyncTests: XCTestCase {
  private final class Server: Sendable {
    let calls = Mutex<[(String, [String: JSONValue])]>([])
    let state = Mutex<[[String: JSONValue]]>([])
    func client() -> OpenCodeClient {
      OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4189/sync-\(UUID().uuidString)")!)) { [self] request in
        let method = request.url!.lastPathComponent
        let input = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data()))?.object?["input"]?.object ?? [:]
        calls.withLock { $0.append((method, input)) }
        func ok(_ output: JSONValue) -> (Data, URLResponse) {
          (try! JSONEncoder().encode(JSONValue.object(["output": output])),
           HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        switch method {
        case "info": return ok(.object(["version": .number(1), "limits": .object([:])]))
        case "list":
          return ok(.object(["sessionID": .string("ses_sync"), "revision": .number(1),
            "quotes": .array(state.withLock { $0 }.map { .object($0) }), "dismissed": .array([])]))
        case "save":
          if input["quote"]?.object?["id"]?.string == "sent-1" {
            let body = Data(#"{"_tag":"RpcError","type":"already_sent","message":"sent","data":{"ids":["sent-1"]}}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
          }
          var quote = input["quote"]?.object ?? [:]
          quote["attachments"] = .array([])
          quote["createdAt"] = .number(1)
          quote["updatedAt"] = .number(1)
          quote["revision"] = .number(2)
          return ok(.object(["revision": .number(2), "quote": .object(quote)]))
        default: return ok(.object(["revision": .number(3)]))
        }
      }
    }
  }
  private func quote(_ id: String) -> [String: JSONValue] {
    ["id": .string(id), "messageID": .string("msg_a"), "partID": .string("msg_a:text:0"), "text": .string("Trecho"),
     "comment": .string("Pendente"), "attachments": .array([]), "createdAt": .number(1), "updatedAt": .number(1),
     "revision": .number(1)]
  }

  func testUndoRestoredQuotesBecomeNewQuotesAndReplaceThePendingOnes() async throws {
    let server = Server()
    server.state.withLock { $0 = [quote("pending-1")] }
    let draft = ConversationDraft(server: "http://127.0.0.1:4189", id: "ses_sync_\(UUID().uuidString)")
    let sync = QuoteSync(sessionID: "ses_sync", client: server.client(), modes: QuoteModes(), dismissals: nil)
    sync.draft = draft
    sync.directory = "/repo"
    draft.quoteSync = sync
    await sync.start()
    XCTAssertEqual(draft.quotes.map(\.id), ["pending-1"])
    // Undo puts the sent message's quote (a tombstoned ID) back into the composer.
    draft.quotes = [ChatQuote(id: "sent-1", messageID: "msg_a", partID: "msg_a:text:0", text: "Trecho", comment: "Enviado")]
    await sync.restored()
    let restored = try XCTUnwrap(draft.quotes.first?.id)
    XCTAssertNotEqual(restored, "sent-1")
    let calls = server.calls.withLock { $0 }
    let clear = try XCTUnwrap(calls.first { $0.0 == "clear" }?.1)
    XCTAssertEqual(clear["ids"], .array([.string("pending-1")]))
    XCTAssertEqual(clear["reason"], .string("discarded"))
    XCTAssertEqual(calls.filter { $0.0 == "save" }.compactMap { $0.1["quote"]?.object?["id"]?.string }, [restored])
    try await draft.discard()
  }

  func testQueuedPromptQuotesStayALocalPreview() async throws {
    let server = Server()
    let draft = ConversationDraft(server: "http://127.0.0.1:4189", id: "ses_sync_\(UUID().uuidString)")
    let sync = QuoteSync(sessionID: "ses_sync", client: server.client(), modes: QuoteModes(), dismissals: nil)
    sync.draft = draft
    sync.directory = "/repo"
    draft.quoteSync = sync
    await sync.start()
    let item = try JSONDecoder().decode(InboxItem.self, from: Data(#"""
      {"id":"msg_queued","sessionID":"ses_sync","type":"user","delivery":"queue","payload":{"text":"Fila",
       "metadata":{"displayText":"Fila","comments":[],"quotes":[{"id":"sent-1","messageID":"msg_a","partID":"msg_a:text:0","text":"Trecho","comment":"Na fila"}]}}}
      """#.utf8))
    draft.restore(item)
    let editor = draft.commentEditor(draft.quotes[0])
    editor.text = NSAttributedString(string: "Editado na fila")
    await draft.commit(draft.quotes[0], from: editor)
    await sync.reload()
    XCTAssertEqual(draft.quotes.map(\.comment), ["Editado na fila"])
    XCTAssertTrue(server.calls.withLock { $0 }.allSatisfy { !["save", "remove", "clear"].contains($0.0) })
    try await editor.discard()
    try await draft.discard()
  }
}
