import SwiftUI
import XCTest

@testable import OpenCode
@testable import OpenCodeKit

@MainActor final class SessionNoticeTests: XCTestCase {
  func testIncompatibleNoticeFromInfoWithoutVersion() async throws {
    let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://127.0.0.1:4177")!)) { request in
      return (Data("{}".utf8), HTTPURLResponse(url: request.url!,
        statusCode: request.url?.path == "/api/info" ? 200 : 404, httpVersion: nil, headerFields: nil)!)
    }
    let store = ConversationStore(id: "ses_notice_test", client: client, hub: EventHub(client: client))
    await store.refresh()
    XCTAssertEqual(store.notice, .incompatible)
    let notice = try XCTUnwrap(store.notice)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    defer { window.isHidden = true; previous?.makeKeyAndVisible() }
    for mode in ["dark", "light"] {
      let theme = AppTheme.load("openchamber-" + mode)
      window.rootViewController = UIHostingController(rootView:
        VStack(spacing: 0) {
          ConversationNoticeView(notice: notice, retry: {})
          Spacer()
        }
        .background(theme.color(.background).ignoresSafeArea())
        .environment(\.appTheme, theme).tint(theme.color(.primary))
        .preferredColorScheme(mode == "dark" ? .dark : .light))
      window.makeKeyAndVisible()
      window.layoutIfNeeded()
      await Task.yield()
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: image)
      attachment.name = "incompatible-component-" + mode
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }
}
