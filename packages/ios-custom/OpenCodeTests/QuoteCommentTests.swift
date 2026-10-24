import OpenCodeKit
import XCTest

@testable import OpenCode

@MainActor final class QuoteCommentTests: XCTestCase {
  func testCommitAdoptsNewAttachmentsDropsRemovedOnesAndNeverSavesTheEditor() async throws {
    let draft = ConversationDraft(server: "http://127.0.0.1:4183", id: "quote-comment-\(UUID().uuidString)")
    await draft.load()
    var quote = ChatQuote(messageID: "msg_a", partID: "msg_a:text:0", text: "Trecho citado")
    let kept = DraftAttachment(name: "mantido.png", mime: "image/png", size: 3, quoteID: quote.id)
    let removed = DraftAttachment(name: "removido.pdf", mime: "application/pdf", size: 3, quoteID: quote.id)
    let message = DraftAttachment(name: "mensagem.png", mime: "image/png", size: 3)
    for attachment in [kept, removed, message] { try await draft.persistence.store(Data([1, 2, 3]), attachment: attachment) }
    quote.commentPrompt = [kept.commentPart, removed.commentPart]
    quote.document = ComposerDocument(text: "Antes")
    draft.attachments = [message, kept, removed]
    draft.quotes = [quote]

    let editor = draft.commentEditor(quote)
    XCTAssertEqual(editor.document.text, "Antes")
    XCTAssertNotEqual(editor.persistence.directory, draft.persistence.directory)
    draft.lend(quote, to: editor)
    XCTAssertEqual(editor.attachments.map(\.id), [kept.id, removed.id])
    XCTAssertTrue(editor.attachments.allSatisfy { $0.quoteID == nil })
    XCTAssertTrue(FileManager.default.fileExists(atPath: editor.persistence.file(kept).path))

    // `remove(_:)` also cleans files in a detached task; the commit itself must drop the file.
    editor.attachments.removeLast()
    let added = DraftAttachment(name: "novo.jpg", mime: "image/jpeg", size: 4)
    try await editor.persistence.store(Data([4, 5, 6, 7]), attachment: added)
    editor.attachments.append(added)
    editor.text = NSAttributedString(string: "Depois")
    await editor.persist()
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: editor.persistence.directory.appendingPathComponent("draft.json").path))

    await draft.commit(quote, from: editor)
    XCTAssertEqual(draft.attachments.map(\.id), [message.id, kept.id, added.id])
    XCTAssertEqual(draft.attachments.filter { $0.quoteID == quote.id }.map(\.id), [kept.id, added.id])
    let adopted = try await draft.persistence.bytes(added)
    XCTAssertEqual(adopted, Data([4, 5, 6, 7]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: editor.persistence.file(added).path))
    let committed = try XCTUnwrap(draft.quotes.first)
    XCTAssertEqual(committed.comment, "Depois")
    XCTAssertEqual(committed.attachmentParts.compactMap { $0.object?["id"]?.string }, [kept.id, added.id])
    XCTAssertEqual(committed.attachmentParts.last?.object?["type"], .string("image"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: draft.persistence.file(removed).path))

    try await editor.discard()
    XCTAssertFalse(FileManager.default.fileExists(atPath: editor.persistence.directory.path))
    XCTAssertEqual(draft.quotes.count, 1)
    try await draft.discard()
  }

  func testCancelledEditorLeavesTheMessageDraftUntouched() async throws {
    let draft = ConversationDraft(server: "http://127.0.0.1:4183", id: "quote-comment-\(UUID().uuidString)")
    await draft.load()
    let quote = ChatQuote(messageID: "msg_a", partID: "msg_a:text:0", text: "Trecho citado")
    let editor = draft.commentEditor(quote)
    draft.lend(quote, to: editor)
    let added = DraftAttachment(name: "novo.jpg", mime: "image/jpeg", size: 4)
    try await editor.persistence.store(Data([4, 5, 6, 7]), attachment: added)
    editor.attachments.append(added)
    editor.text = NSAttributedString(string: "Descartado")
    try await editor.discard()
    XCTAssertTrue(draft.quotes.isEmpty)
    XCTAssertTrue(draft.attachments.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: draft.persistence.file(added).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: editor.persistence.directory.path))
    try await draft.discard()
  }
}
