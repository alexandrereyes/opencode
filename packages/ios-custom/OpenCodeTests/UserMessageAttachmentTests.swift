import OpenCodeKit
import SwiftUI
import XCTest

@testable import OpenCode

@MainActor final class UserMessageAttachmentTests: XCTestCase {
  func testSearchResultRemainsVisibleBelowQuotedContext() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    for text in ["Resultado final.", Array(repeating: "Linha de contexto.", count: 40).joined(separator: "\n") + "\nResultado final."] {
      let window = UIWindow(windowScene: scene)
      let range = (text as NSString).range(of: "Resultado final.")
      window.rootViewController = UIHostingController(rootView:
        UserMessageContent(maximumHeight: 120) {
          Text("Contexto de uma citação").frame(height: 240)
          UserPrompt(text: AttributedString(text), theme: AppTheme.load("openchamber-dark"), collapsed: false,
            maximumHeight: 120, revealRange: range, truncationChanged: { _ in }, expand: {})
        })
      window.makeKeyAndVisible()
      defer { window.isHidden = true }
      func prompt(_ view: UIView) -> UserPromptScrollView? {
        if let view = view as? UserPromptScrollView { return view }
        return view.subviews.lazy.compactMap { prompt($0) }.first
      }
      let visible = expectation(for: NSPredicate { _, _ in
        guard let view = prompt(window), let viewport = sequence(first: view.superview, next: { $0?.superview })
          .compactMap({ $0 as? UIScrollView }).first else { return false }
        let line = CGRect(x: 0, y: view.label.bounds.maxY - view.label.font.lineHeight,
          width: view.label.bounds.width, height: view.label.font.lineHeight)
        return viewport.bounds.insetBy(dx: -1, dy: -1).contains(view.label.convert(line, to: viewport))
      }, evaluatedWith: window)
      let result = await XCTWaiter.fulfillment(of: [visible], timeout: 5)
      XCTAssertEqual(result, .completed)
    }
  }

  func testImageAndFileMetadataDoNotRepeatVisibleAttachments() throws {
    let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(#"""
      {"id":"msg_attachments","type":"user","time":{"created":0},"text":"Mensagem",
       "files":[{"mime":"image/png","name":"imagem.png","data":"abc"},
                {"mime":"text/plain","name":"arquivo.txt","data":"def"}],
       "metadata":{"attachments":[{"name":"imagem.png"},{"name":"arquivo.txt"},{"name":"outro.pdf"}]}}
      """#.utf8))
    let attachments = UserMessageAttachments(message)
    XCTAssertEqual(attachments.images, [FeedImage(source: "data:image/png;base64,abc", name: "imagem.png")])
    XCTAssertEqual(attachments.files, ["arquivo.txt", "outro.pdf"])
    XCTAssertEqual(message.files?.count, 2)
    XCTAssertEqual(message.metadata?["attachments"]?.array?.count, 3)
  }

  func testAttachmentOnlyMessagesKeepEveryDistinctImageAndFile() throws {
    let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(#"""
      {"id":"msg_files","type":"user","time":{"created":0},
       "files":[{"mime":"image/png","filename":"primeira.png","url":"/primeira.png"},
                {"mime":"image/png","name":"segunda.png","url":"/segunda.png"},
                {"mime":"application/pdf","path":"/docs/relatorio.pdf"}]}
      """#.utf8))
    let attachments = UserMessageAttachments(message)
    XCTAssertEqual(attachments.images.map(\.name), ["primeira.png", "segunda.png"])
    XCTAssertEqual(attachments.files, ["relatorio.pdf"])
    XCTAssertTrue(message.displayText.isEmpty)
  }

  func testDifferentFilesWithTheSameNameAreNotDiscarded() throws {
    let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(#"""
      {"id":"msg_same_names","type":"user","time":{"created":0},
       "files":[{"mime":"text/plain","name":"leia.txt","uri":"/a/leia.txt"},
                {"mime":"text/plain","name":"leia.txt","uri":"/b/leia.txt"}],
       "metadata":{"attachments":[{"name":"leia.txt"}]}}
      """#.utf8))
    XCTAssertEqual(UserMessageAttachments(message).files, ["leia.txt", "leia.txt"])
  }
}
