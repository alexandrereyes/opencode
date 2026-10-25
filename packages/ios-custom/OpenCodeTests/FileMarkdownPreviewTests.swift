@testable import OpenCodeKit
import SwiftUI
import UIKit
import XCTest
@testable import OpenCode

@MainActor final class FileMarkdownPreviewTests: XCTestCase {
  /// Every mounted text view holds bitmaps for its whole height; drawing a long document at once took the
  /// footprint from 57 MB to 1.9 GB for this package's README. Only slices near the viewport may be mounted.
  func testLongDocumentMountsOnlyTheSlicesNearTheViewport() async throws {
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:9")!)) { request in
      (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
    let fixture = try String(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "markdown-fixture", withExtension: "md")), encoding: .utf8)
    let text = Array(repeating: fixture, count: 12).joined(separator: "\n\n")
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    let host = UIHostingController(rootView: FileMarkdownPreview(text: text, path: "/repo/docs/guia.md",
      context: ConversationImageContext(client: client, directory: "/repo", sessionID: "ses_file")))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    func mounted(in view: UIView) -> [ResponseTextView] {
      ((view as? ResponseTextView).map { [$0] } ?? []) + view.subviews.flatMap { mounted(in: $0) }
    }
    for _ in 0..<200 where mounted(in: host.view).isEmpty {
      try await Task.sleep(for: .milliseconds(100))
      host.view.layoutIfNeeded()
    }
    let views = mounted(in: host.view)
    XCTAssertFalse(views.isEmpty)
    let height = views.reduce(0) { $0 + $1.bounds.height }
    XCTAssertLessThan(height, 874 * 8, "mounted text height")
    XCTAssertTrue(views.contains { $0.attributedText.string.contains("Formatação") })
  }
}
