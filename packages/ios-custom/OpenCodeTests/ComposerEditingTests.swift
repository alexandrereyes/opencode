import Observation
import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import OpenCode

@MainActor private struct ComposerEditingHost: View {
  let draft: ConversationDraft
  let owner: UUID
  let expanded: Bool
  var theme = AppTheme.selected
  var importImages: (([NSItemProvider]) -> Void)? = nil
  var body: some View {
    ComposerTextView(draft: draft, theme: theme, expanded: expanded, owner: owner, importImages: importImages).padding(30)
  }
}

private final class PastedImages {
  var providers: [NSItemProvider] = []
}

/// Stands in for UIKit's paste item, whose concrete class is private: the text view's paste delegate decides each item.
private final class PasteItem: NSObject, UITextPasteItem {
  let itemProvider: NSItemProvider
  var localObject: Any? { nil }
  var defaultAttributes: [NSAttributedString.Key: Any] { [:] }
  var result = "pending"
  init(_ provider: NSItemProvider) { itemProvider = provider }
  func setResult(string: String) { result = "string" }
  func setResult(attributedString: NSAttributedString) { result = "attributed" }
  func setResult(attachment: NSTextAttachment) { result = "attachment" }
  func setNoResult() { result = "none" }
  func setDefaultResult() { result = "default" }
}

private func pngProvider(_ color: UIColor) -> NSItemProvider {
  let provider = NSItemProvider()
  let data = pngData(color)
  provider.registerDataRepresentation(for: .png, visibility: .all) { completion in
    completion(data, nil)
    return nil
  }
  return provider
}

private func pngData(_ color: UIColor, size: CGSize = CGSize(width: 24, height: 16)) -> Data {
  UIGraphicsImageRenderer(size: size).pngData { context in
    color.setFill()
    context.fill(CGRect(origin: .zero, size: size))
  }
}

@MainActor final class ComposerEditingTests: XCTestCase {
  func testSuccessfulSubmissionResetsOnlyRuntimePresentation() throws {
    let draft = ConversationDraft(server: "http://127.0.0.1:4177", id: "composer-presentation")
    draft.text = NSAttributedString(string: "Texto mantido até limpar")
    draft.expanded = true
    draft.focused = true
    let snapshot = draft.snapshot
    draft.didSend()
    XCTAssertFalse(draft.expanded)
    XCTAssertFalse(draft.focused)
    XCTAssertEqual(draft.sendRevision, 1)
    XCTAssertEqual(draft.snapshot, snapshot)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
    XCTAssertNil(encoded?["expanded"])
    XCTAssertNil(encoded?["sendRevision"])
  }

  private func mount(
    _ document: ComposerDocument, expanded: Bool = true, focused: Bool = true,
    importImages: (([NSItemProvider]) -> Void)? = nil
  ) throws -> (ConversationDraft, UIWindow) {
    let draft = ConversationDraft(server: "http://127.0.0.1:4177", id: "composer-test")
    draft.text = document.attributed
    draft.selection = NSRange(location: document.editorOffset(document.text.utf16.count), length: 0)
    let owner = UUID()
    draft.editorOwner = owner
    draft.focused = focused
    let window = UIWindow(windowScene: try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
    window.rootViewController = UIHostingController(rootView:
      ComposerEditingHost(draft: draft, owner: owner, expanded: expanded, importImages: importImages))
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    return (draft, window)
  }

  private func settle() async throws { try await Task.sleep(for: .milliseconds(40)) }

  /// The edit menu's Colar, ⌘V and the keyboard's "Foto · Colar" suggestion all call `paste(_:)`.
  func testPastedImagesBecomeAttachmentsAndTheirTextIsKept() async throws {
    let pasted = PastedImages()
    let (draft, window) = try mount(ComposerDocument(text: "Veja "), importImages: { pasted.providers += $0 })
    defer { window.isHidden = true; window.rootViewController = nil }
    try await settle()
    let input = try XCTUnwrap(draft.input)
    UIPasteboard.general.items = [
      [UTType.png.identifier: pngData(.red)], [UTType.utf8PlainText.identifier: "legenda &RE"],
      [UTType.png.identifier: pngData(.blue)],
    ]
    XCTAssertTrue(input.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
    input.paste(nil)
    try await settle()
    XCTAssertEqual(pasted.providers.count, 2)
    XCTAssertTrue(pasted.providers.allSatisfy { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) })
    XCTAssertEqual(draft.document.text, "Veja legenda &RE")
    XCTAssertFalse(input.textStorage.string.contains("\u{FFFC}"))
    XCTAssertTrue(draft.document.validTokens.isEmpty)
    // The pasted text still opens a trigger, and undo removes only the text.
    XCTAssertEqual(draft.trigger?.character, "&")
    input.undoManager?.undo()
    try await settle()
    XCTAssertEqual(draft.document.text, "Veja ")
    // Images alone add nothing to the text.
    UIPasteboard.general.items = [[UTType.png.identifier: pngData(.green)]]
    input.paste(nil)
    try await settle()
    XCTAssertEqual(pasted.providers.count, 3)
    XCTAssertEqual(draft.document.text, "Veja ")
    // Text-only pastes are unchanged.
    UIPasteboard.general.string = "só texto"
    input.paste(nil)
    try await settle()
    XCTAssertEqual(draft.document.text, "Veja só texto")
    XCTAssertEqual(pasted.providers.count, 3)
  }

  func testEditorsWithoutAttachmentsIgnorePastedImages() async throws {
    let (draft, window) = try mount(ComposerDocument(text: "Pergunta"))
    defer { window.isHidden = true; window.rootViewController = nil }
    try await settle()
    let input = try XCTUnwrap(draft.input)
    UIPasteboard.general.items = [[UTType.png.identifier: pngData(.red)]]
    input.paste(nil)
    input.paste(itemProviders: [pngProvider(.red)])
    try await settle()
    XCTAssertEqual(input.textStorage.string, "Pergunta")
  }

  func testItemProviderPastesDropsAndRichInsertionsImportImagesWithoutGlyphs() async throws {
    let pasted = PastedImages()
    let (draft, window) = try mount(ComposerDocument(), importImages: { pasted.providers += $0 })
    defer { window.isHidden = true; window.rootViewController = nil }
    try await settle()
    let input = try XCTUnwrap(draft.input)
    let image = pngProvider(.red)
    XCTAssertTrue(input.canPaste([image]))
    input.paste(itemProviders: [image, NSItemProvider(object: "texto" as NSString)])
    XCTAssertEqual(pasted.providers.count, 1)
    await fulfillment(of: [expectation(for: NSPredicate { _, _ in draft.document.text == "texto" }, evaluatedWith: nil)], timeout: 5)
    // Drops reach the paste delegate one item at a time.
    let dropped = PasteItem(pngProvider(.blue))
    input.textPasteConfigurationSupporting(input, transform: dropped)
    XCTAssertEqual(dropped.result, "none")
    XCTAssertEqual(pasted.providers.count, 2)
    let text = PasteItem(NSItemProvider(object: "solto" as NSString))
    input.textPasteConfigurationSupporting(input, transform: text)
    XCTAssertEqual(text.result, "default")
    XCTAssertEqual(pasted.providers.count, 2)
    // A rich insertion keeps its text and imports its image attachment.
    let rich = NSMutableAttributedString(string: " antes ")
    rich.append(NSAttributedString(attachment: NSTextAttachment(image: try XCTUnwrap(UIImage(data: pngData(.green))))))
    rich.append(NSAttributedString(string: "depois"))
    input.insertAttributedText(rich)
    try await settle()
    XCTAssertEqual(pasted.providers.count, 3)
    XCTAssertEqual(draft.document.text, "texto antes depois")
    XCTAssertFalse(input.textStorage.string.contains("\u{FFFC}"))
  }

  func testPastedImagesImportThroughTheAttachmentFlow() async throws {
    let client = OpenCodeClient.scrollFixture(configuration: .launch())
    let store = ConversationStore(id: "paste-images", client: client, hub: EventHub(client: client))
    let draft = ConversationDraft(server: "http://127.0.0.1:4177", id: "paste-images-\(UUID().uuidString)")
    defer { Task { try? await draft.persistence.remove() } }
    let wide = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 10)).image { context in
      UIColor.orange.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 3000, height: 10))
    }
    await store.importImages([
      pngProvider(.red),
      NSItemProvider(object: wide),
    ], draft: draft)
    XCTAssertFalse(draft.importing)
    XCTAssertEqual(draft.attachments.count, 2)
    XCTAssertEqual(draft.attachments.first?.mime, "image/png")
    XCTAssertTrue(draft.attachments.allSatisfy { $0.name.hasPrefix("Imagem-") })
    // The "+" flow's conversion applies: an oversized image is scaled down as JPEG.
    XCTAssertEqual(draft.attachments.last?.mime, "image/jpeg")
    for attachment in draft.attachments {
      let bytes = try await draft.persistence.bytes(attachment)
      XCTAssertEqual(bytes.count, attachment.size)
    }
  }

  func testSendingDisablesFocusedEditorOutsideTheSwiftUIGraphUpdate() async throws {
    let (draft, window) = try mount(ComposerDocument(text: "Envio de exemplo"), expanded: false)
    defer { window.isHidden = true; window.rootViewController = nil }
    await fulfillment(of: [expectation(for: NSPredicate { _, _ in draft.input != nil }, evaluatedWith: nil)], timeout: 5)
    let input = try XCTUnwrap(draft.input)
    await fulfillment(of: [expectation(for: NSPredicate { _, _ in input.isFirstResponder }, evaluatedWith: nil)], timeout: 5)
    draft.sending = true
    await fulfillment(of: [expectation(for: NSPredicate { _, _ in
      !input.isEditable && !input.isFirstResponder
    }, evaluatedWith: nil)], timeout: 5)
    draft.sending = false
    await fulfillment(of: [expectation(for: NSPredicate { _, _ in input.isEditable }, evaluatedWith: nil)], timeout: 5)
    draft.focused = true
    await fulfillment(of: [expectation(for: NSPredicate { _, _ in input.isFirstResponder }, evaluatedWith: nil)], timeout: 5)
    XCTAssertEqual(input.text, "Envio de exemplo")
  }

  func testTypingCostAndSelection() async throws {
    let profiling = ProcessInfo.processInfo.environment["OPENCODE_PROFILE_COMPOSER"] == "1"
    let iterations = profiling ? 200 : 30
    if profiling {
      print("COMPOSER_PROFILE_READY pid=\(ProcessInfo.processInfo.processIdentifier)")
      fflush(nil)
      try await Task.sleep(for: .seconds(2))
    }
    for count in [1, 100, 500] {
      var document = ComposerDocument()
      for index in 0..<count {
        let token = ComposerToken(kind: .skill, id: "skill-\(index)", text: "$skill-\(index)")
        let start = document.text.utf16.count
        document.text += token.text
        document.tokens.append(.init(start: start, end: document.text.utf16.count, token: token))
        document.text += " Texto da linha para editar e selecionar.\n"
      }
      let (draft, window) = try mount(document)
      try await settle()
      let input = try XCTUnwrap(draft.input)
      let attachment = try XCTUnwrap(input.textStorage.attribute(.attachment, at: 0, effectiveRange: nil) as? ComposerTokenAttachment)
      let revision = draft.sourceRevision
      var samples: [Double] = []
      for _ in 0..<iterations {
        let start = CACurrentMediaTime()
        input.insertText("a")
        window.layoutIfNeeded()
        samples.append((CACurrentMediaTime() - start) * 1000)
        try await settle()
      }
      print("COMPOSER_COST tokens=\(count) utf16=\(document.text.utf16.count) mean_ms=\(samples.reduce(0,+)/Double(samples.count)) max_ms=\(samples.max()!)")
      XCTAssertTrue(draft.document.text.hasSuffix(String(repeating: "a", count: iterations)))
      XCTAssertEqual(draft.document.validTokens.count, count)
      XCTAssertEqual(draft.sourceRevision, revision)
      XCTAssertTrue(attachment === (input.textStorage.attribute(.attachment, at: 0, effectiveRange: nil) as? ComposerTokenAttachment))
      if !profiling && count == 500 { XCTAssertLessThan(samples.sorted()[samples.count / 2], 16.67) }
      input.resignFirstResponder()
      window.isHidden = true
    }
  }

  func testNativeSelectionAndUndoAtToken() async throws {
    let token = ComposerToken(kind: .skill, id: "sample", text: "$sample")
    let (draft, window) = try mount(.init(text: "$sample prose", tokens: [.init(start: 0, end: 7, token: token)]))
    defer { window.isHidden = true }
    try await settle()
    let input = try XCTUnwrap(draft.input)
    input.selectedRange = NSRange(location: 1, length: 0)
    input.deleteBackward()
    try await settle()
    XCTAssertEqual(draft.document.text, " prose")
    XCTAssertTrue(input.undoManager?.canUndo == true, "Deleting a token must participate in native undo")
    input.undoManager?.undo()
    try await settle()
    XCTAssertEqual(draft.document.text, "$sample prose")
    XCTAssertEqual(draft.document.validTokens.count, 1)
  }

  func testSelectionCopyPasteAndReplacementAcrossAtomicTokens() async throws {
    let token = ComposerToken(kind: .skill, id: "sample", text: "$sample")
    let source = ComposerDocument(text: "a $sample z", tokens: [.init(start: 2, end: 9, token: token)])
    let (draft, window) = try mount(source)
    defer { window.isHidden = true }
    try await settle()
    let input = try XCTUnwrap(draft.input)
    XCTAssertEqual(input.textStorage.string, "a \u{FFFC} z")
    input.selectedRange = NSRange(location: 1, length: 3)
    try await settle()
    XCTAssertEqual(input.selectedRange, NSRange(location: 1, length: 3))
    input.copy(nil)
    XCTAssertEqual(UIPasteboard.general.string, " $sample ")
    input.selectedRange = NSRange(location: input.textStorage.length, length: 0)
    input.paste(nil)
    try await settle()
    XCTAssertEqual(draft.document.text, "a $sample z $sample ")
    XCTAssertEqual(draft.document.validTokens.count, 2)
    input.selectedRange = NSRange(location: 1, length: 3)
    input.insertText("ABC")
    try await settle()
    XCTAssertEqual(draft.document.text, "aABCz $sample ")
    XCTAssertEqual(draft.document.validTokens.count, 1)
  }

  func testMarkedTextAndSelectionSurviveSwiftUIUpdates() async throws {
    let token = ComposerToken(kind: .skill, id: "sample", text: "$sample")
    let (draft, window) = try mount(.init(text: "$sample fim", tokens: [.init(start: 0, end: 7, token: token)]))
    defer { window.isHidden = true }
    try await settle()
    let input = try XCTUnwrap(draft.input)
    input.selectedRange = NSRange(location: 2, length: 0)
    input.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
    let range = input.selectedRange
    let host = try XCTUnwrap(window.rootViewController as? UIHostingController<ComposerEditingHost>)
    host.rootView.theme = .load("openchamber-light")
    try await settle()
    XCTAssertNotNil(input.markedTextRange)
    XCTAssertEqual(input.selectedRange, range)
    input.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0))
    input.unmarkText()
    input.insertText(" ")
    try await settle()
    XCTAssertEqual(draft.document.text, "$sample 日本語 fim")
    XCTAssertEqual(input.composerTheme.id, "openchamber-light")
    XCTAssertEqual(draft.document.validTokens.count, 1)
    input.selectedRange = NSRange(location: 2, length: 3)
    input.insertText("correção")
    try await settle()
    XCTAssertEqual(draft.document.text, "$sample correção fim")
    XCTAssertEqual(draft.document.validTokens.count, 1)
  }

  func testLegacyDraftAndWireEncodingRemainIdentical() async throws {
    let json = #"{"document":{"text":"😀 $sample fim","tokens":[{"start":3,"end":10,"token":{"kind":"skill","id":"sample","text":"$sample"}}]},"attachments":[],"cursor":11}"#
    let snapshot = try JSONDecoder().decode(DraftSnapshot.self, from: Data(json.utf8))
    let (draft, window) = try mount(snapshot.document)
    defer { window.isHidden = true }
    try await settle()
    let input = try XCTUnwrap(draft.input)
    input.selectedRange = NSRange(location: snapshot.document.editorOffset(snapshot.cursor), length: 0)
    try await settle()
    XCTAssertEqual(draft.snapshot.document, snapshot.document)
    XCTAssertEqual(draft.snapshot.cursor, snapshot.cursor)
    let model = ModelReference(id: "gpt-6-luna", providerID: "llm-proxy", variant: "low")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let before = PromptRequest(id: "msg_test", document: snapshot.document, delivery: .steer, agent: "build", model: model)
    let after = PromptRequest(id: "msg_test", document: draft.document, delivery: .steer, agent: "build", model: model)
    XCTAssertEqual(try encoder.encode(before), try encoder.encode(after))
  }

  func testTypingAtStartBetweenAndAfterTokensAndSuggestionUndo() async throws {
    let token = ComposerToken(kind: .skill, id: "sample", text: "$sample")
    let (draft, window) = try mount(.init(text: "$sample$sample", tokens: [
      .init(start: 0, end: 7, token: token), .init(start: 7, end: 14, token: token),
    ]))
    defer { window.isHidden = true }
    try await settle()
    let input = try XCTUnwrap(draft.input)
    input.selectedRange = NSRange(location: 1, length: 0)
    for _ in 0..<30 { input.insertText("x") }
    input.selectedRange = NSRange(location: 0, length: 0)
    input.insertText("começo ")
    input.selectedRange = NSRange(location: input.textStorage.length, length: 0)
    input.insertText(" fim")
    try await settle()
    XCTAssertEqual(draft.document.text, "começo $sample" + String(repeating: "x", count: 30) + "$sample fim")
    XCTAssertEqual(draft.document.validTokens.count, 2)
    input.insertText(" $sam")
    try await settle()
    let trigger = try XCTUnwrap(draft.trigger)
    draft.insert(token, replacing: trigger.range)
    try await settle()
    XCTAssertEqual(draft.document.validTokens.count, 3)
    input.undoManager?.undo()
    try await settle()
    XCTAssertTrue(draft.document.text.hasSuffix(" $sam"))
    XCTAssertEqual(draft.document.validTokens.count, 2)
    input.undoManager?.redo()
    try await settle()
    XCTAssertEqual(draft.document.validTokens.count, 3)
  }

  func testAmpersandOpensFilesOnlyAtABoundaryAndInsertsTheFileTokenWithUndo() async throws {
    let (draft, window) = try mount(.init())
    defer { window.isHidden = true }
    try await settle()
    let input = try XCTUnwrap(draft.input)
    for prose in ["R&D", " AT&T", " a &&", " b", " 😀&", " (&", " ?a=1&b=2", " !RE", " Pode arrumar!"] {
      input.insertText(prose)
      XCTAssertNil(draft.trigger, prose)
    }
    // A lone `&` opens; the space after it closes the panel and inserts nothing.
    input.insertText(" Tom &")
    XCTAssertEqual(draft.trigger?.character, "&")
    input.insertText(" Jerry")
    XCTAssertNil(draft.trigger)
    XCTAssertTrue(draft.document.text.hasSuffix(" Tom & Jerry"))
    XCTAssertTrue(draft.document.validTokens.isEmpty)
    // A paste on a new line starts a word, like typing.
    input.insertText("\n&RE")
    XCTAssertEqual(draft.trigger?.character, "&")
    XCTAssertEqual(draft.trigger?.query, "RE")
    try await settle()
    let file = ComposerToken(kind: .file, id: "README.md", text: "@README.md", value: "/repo/README.md")
    draft.insert(file, replacing: try XCTUnwrap(draft.trigger).range)
    try await settle()
    XCTAssertEqual(draft.document.validTokens.map(\.token), [file])
    XCTAssertTrue(draft.document.text.hasSuffix("\n@README.md "))
    XCTAssertNil(draft.trigger)
    input.undoManager?.undo()
    try await settle()
    XCTAssertTrue(draft.document.text.hasSuffix("\n&RE"), draft.document.text)
    XCTAssertTrue(draft.document.validTokens.isEmpty)
    input.undoManager?.redo()
    try await settle()
    XCTAssertEqual(draft.document.validTokens.map(\.token), [file])
    input.deleteBackward()
    input.insertText("&")
    XCTAssertNil(draft.trigger, "`&` right after a token is prose")
    XCTAssertTrue(draft.document.text.hasSuffix("\n@README.md&"), draft.document.text)
  }

  func testTypingPublishesDerivedComposerStateOnlyWhenItChanges() async throws {
    let (draft, window) = try mount(.init())
    defer { window.isHidden = true }
    try await settle()
    let input = try XCTUnwrap(draft.input)
    final class Flag: @unchecked Sendable { var raised = false }
    // The composer card and the conversation observe these; a plain keystroke must not invalidate them.
    func publishes(_ action: () -> Void) -> Bool {
      let flag = Flag()
      withObservationTracking { _ = (draft.hasText, draft.isEmpty, draft.trigger) } onChange: { flag.raised = true }
      action()
      return flag.raised
    }
    XCTAssertTrue(publishes { input.insertText("O") })
    XCTAssertTrue(draft.hasText)
    XCTAssertFalse(draft.isEmpty)
    XCTAssertFalse(publishes { input.insertText("lá, mundo") })
    XCTAssertFalse(publishes { input.deleteBackward() })
    XCTAssertTrue(publishes { input.insertText(" @RE") })
    XCTAssertEqual(draft.trigger?.character, "@")
    XCTAssertEqual(draft.trigger?.query, "RE")
    XCTAssertTrue(publishes { input.insertText("A") })
    XCTAssertEqual(draft.trigger?.query, "REA")
    XCTAssertTrue(publishes { draft.dismissSuggestions() })
    XCTAssertNil(draft.trigger)
    input.insertText("D")
    XCTAssertEqual(draft.trigger?.query, "READ")
    XCTAssertTrue(publishes { draft.focused = false })
    XCTAssertNil(draft.trigger)
    draft.focused = true
    XCTAssertEqual(draft.trigger?.query, "READ")
    XCTAssertTrue(publishes { draft.text = NSAttributedString(string: "  \n") })
    XCTAssertFalse(draft.hasText)
    XCTAssertFalse(draft.isEmpty)
    XCTAssertNil(draft.trigger)
  }

  func testCollapsedEditorGrowsAndExternalReplacementWaitsForComposition() async throws {
    let (draft, window) = try mount(.init(), expanded: false)
    defer { window.isHidden = true }
    try await settle()
    let input = try XCTUnwrap(draft.input)
    let initial = input.bounds.height
    input.insertText("primeira\nsegunda\nterceira\nquarta")
    try await settle()
    window.layoutIfNeeded()
    XCTAssertGreaterThan(input.bounds.height, initial)
    input.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
    draft.text = NSAttributedString(string: "substituição externa")
    draft.selection = NSRange(location: 0, length: 0)
    try await settle()
    XCTAssertNotNil(input.markedTextRange)
    input.unmarkText()
    input.insertText(" ")
    try await settle()
    XCTAssertEqual(input.textStorage.string, "substituição externa")
    XCTAssertEqual(draft.document.text, "substituição externa")
  }

  func testEveryTokenKindRoundTripsWithoutChangingMetadata() throws {
    var document = ComposerDocument(text: "😀\r\n")
    for kind in [ComposerTokenKind.file, .reference, .session, .agent, .command, .skill, .snippet, .app] {
      let token = ComposerToken(kind: kind, id: "id-\(kind.rawValue)", text: "@\(kind.rawValue)", value: "/repo/á", detail: ["id": .string("id"), "title": .string("ação")])
      let start = document.text.utf16.count
      document.text += token.text
      document.tokens.append(.init(start: start, end: document.text.utf16.count, token: token))
      document.text += " "
    }
    XCTAssertEqual(ComposerDocument(editor: document.editorAttributed()), document)
  }

  func testLongDraftRestoresCompactHeightWithoutAnEdit() async throws {
    for focused in [false, true] {
      let (draft, window) = try mount(
        .init(text: String(repeating: "texto longo\n", count: 500)), expanded: false, focused: focused)
      defer { window.isHidden = true }
      let input = try XCTUnwrap(draft.input)
      let line = input.composerFont.lineHeight
      let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        input.bounds.height > line * 4
      }, object: nil)
      let result = await XCTWaiter.fulfillment(of: [restored], timeout: 2)
      print("COMPOSER_HEIGHT restored focused=\(focused) height=\(input.bounds.height) content=\(input.contentSize.height) font=\(input.composerFont.pointSize)")
      XCTAssertEqual(result, .completed, "Restored height must not depend on keyboard focus: \(focused)")
      XCTAssertLessThanOrEqual(input.bounds.height, ceil(line * 6 + 2))
      XCTAssertTrue(input.isScrollEnabled)
    }
  }

}
