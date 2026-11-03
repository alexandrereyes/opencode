import Foundation
import Synchronization
import XCTest

@testable import OpenCode
@testable import OpenCodeKit

/// `SessionStore.entry` and `progress` look rows up by an index built on the first lookup after each list: a new list
/// (rows removed, added or changed) must never answer from the previous one.
@MainActor final class SessionEntryIndexTests: XCTestCase {
  private static func row(_ id: String, extra: String = "") -> String {
    #"{"session":{"id":"\#(id)","projectID":"global","title":"\#(id)","location":{"directory":"/owned"},"time":{"created":1,"updated":1}}\#(extra)}"#
  }
  private static let progress =
    #","progress":{"done":1,"finished":1,"total":2,"current":"Rodar os testes","todos":[{"content":"Ler","status":"completed"},{"content":"Rodar os testes","status":"in_progress"}]}"#

  func testLookupsFollowEachNewList() async throws {
    let rows = Mutex([Self.row("ses_a", extra: Self.progress), Self.row("ses_b")])
    let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:4177/test-" + UUID().uuidString)!)
    let prefix = configuration.url.path
    let client = OpenCodeClient(configuration: configuration) { request in
      let path = String(request.url!.path.dropFirst(prefix.count))
      let body = switch path {
      case "/api/info": #"{"version":"test"}"#
      case "/api/rpc/custom.navigation/list": #"{"output":{"data":[\#(rows.withLock { $0.joined(separator: ",") })]}}"#
      case "/api/rpc/custom.preferences/get":
        #"{"output":{"revision":1,"data":{"projects":{},"pinnedSessions":[],"settings":{"autoApprove":false}}}}"#
      case "/api/project": "[]"
      case "/api/session/active": #"{"data":{}}"#
      case "/api/rpc/custom.requests/permissions": #"{"output":[]}"#
      case "/api/session": #"{"data":[],"cursor":{}}"#
      default: ""
      }
      return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: body.isEmpty ? 404 : 200,
        httpVersion: nil, headerFields: nil)!)
    }
    let store = SessionStore(configuration: configuration, acceptsLaunchSession: false, client: client)
    await store.reload()
    XCTAssertNil(store.error)
    XCTAssertEqual(store.progress("ses_a")?.current?.content, "Rodar os testes")
    XCTAssertNotNil(store.entry("ses_b"))
    XCTAssertNil(store.entry("ses_c"))

    rows.withLock { $0 = [Self.row("ses_b", extra: #","backgroundCount":1"#), Self.row("ses_c", extra: Self.progress)] }
    await store.reload()
    XCTAssertNil(store.entry("ses_a"))
    XCTAssertNil(store.progress("ses_a"))
    XCTAssertEqual(store.entry("ses_b")?.backgroundCount, 1)
    XCTAssertEqual(store.progress("ses_c")?.current?.content, "Rodar os testes")
    await store.stop()
  }
}
