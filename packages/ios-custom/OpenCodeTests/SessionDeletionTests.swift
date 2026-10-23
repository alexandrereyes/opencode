import Foundation
import UIKit
import XCTest

@testable import OpenCode
@testable import OpenCodeKit

@MainActor final class SessionDeletionTests: XCTestCase {
  private func session(_ id: String, parent: String? = nil) throws -> Session {
    let parentJSON = parent.map { ",\"parentID\":\"\($0)\"" } ?? ""
    return try JSONDecoder().decode(Session.self, from: Data("""
      {"id":"\(id)","projectID":"global","title":"Excluir","location":{"directory":"/owned"},"time":{"created":1,"updated":1}\(parentJSON)}
      """.utf8))
  }

  func testSuccessCleansChildDraftsAndReadingWithoutLateWriteResurrection() async throws {
    let root = try session("ses_root")
    let child = try session("ses_child", parent: root.id)
    let family = try JSONEncoder().encode(["output": FamilyPage(data: [child], next: nil)])
    let prefs = Data(#"{"output":{"revision":1,"data":{"projects":{},"pinnedSessions":[],"settings":{"autoApprove":false}}}}"#.utf8)
    let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:4177/test-" + UUID().uuidString)!)
    let client = OpenCodeClient(configuration: configuration) { request in
      let data = request.url!.path.hasSuffix("/page") ? family : prefs
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let store = SessionStore(configuration: configuration, client: client)
    let draft = store.drafts.draft(child.id)
    await draft.load()
    draft.text = NSAttributedString(string: "rascunho de filho")
    await draft.persist()
    store.reading.set(.init(.message(id: "old", offset: 42)), sessionID: child.id)
    store.expansions.set(["tool": true], sessionID: child.id)
    store.conversationPath = [.init(id: root.id), .init(id: child.id, parent: root.id)]
    await store.delete(root)
    XCTAssertEqual(store.deletedIDs, [root.id, child.id])
    XCTAssertTrue(store.conversationPath.isEmpty)
    XCTAssertNil(store.reading.position(child.id))
    XCTAssertTrue(store.expansions.values(child.id).isEmpty)
    await draft.persist()
    await store.drafts.draft(child.id).persist()
    let saved = try await draft.persistence.load()
    XCTAssertNil(saved.0)
    XCTAssertEqual(draft.text.length, 0)
    await store.stop()
  }

  func testDeleteFailureRetainsDraftPositionAndNavigation() async throws {
    let root = try session("ses_failure")
    let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:4177/test-" + UUID().uuidString)!)
    let client = OpenCodeClient(configuration: configuration) { request in
      let status = request.httpMethod == "DELETE" ? 503 : 200
      return (Data(#"{"output":{"data":[]}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    let store = SessionStore(configuration: configuration, client: client)
    let draft = store.drafts.draft(root.id)
    await draft.load()
    draft.text = NSAttributedString(string: "preservar")
    store.reading.set(.init(.followTail), sessionID: root.id)
    store.conversationPath = [.init(id: root.id)]
    await store.delete(root)
    XCTAssertTrue(store.deletedIDs.isEmpty)
    XCTAssertEqual(store.conversationPath.last?.id, root.id)
    XCTAssertEqual(draft.text.string, "preservar")
    XCTAssertNotNil(store.reading.position(root.id))
    await store.stop()
    try await draft.discard()
    try store.reading.remove([root.id])
  }

  func testDeleteActionIsDestructiveAndStableAcrossUnrelatedUpdates() throws {
    let button = UIButton(type: .system)
    let coordinator = ConversationOptionsMenu.Coordinator()
    let menu = ConversationOptionsMenu(sessionID: "ses_delete", available: true, canArchive: false,
      archiving: false, theme: .selected, actions: .init(search: {}, rename: {}, details: {}, archive: {}, delete: {}))
    menu.update(button, coordinator: coordinator)
    let original = button.menu
    menu.update(button, coordinator: coordinator)
    XCTAssertTrue(original === button.menu)
    let section = try XCTUnwrap(button.menu?.children.last as? UIMenu)
    let action = try XCTUnwrap(section.children.first as? UIAction)
    XCTAssertEqual(action.title, "Excluir sessão")
    XCTAssertTrue(action.attributes.contains(.destructive))
    XCTAssertFalse(action.attributes.contains(.disabled))
  }
}
