import OpenCodeKit
import SwiftUI
import XCTest

@testable import OpenCode

@MainActor private struct SideQuestionHost: View {
  @Bindable var store: ConversationStore
  var body: some View {
    Color.clear.sheet(item: $store.sideQuestion) { SideQuestionSheet(store: store, launch: $0) }
  }
}

@MainActor final class SideQuestionPresentationTests: XCTestCase {
  func testSheetOpensLargeAndFocusesItsFieldOnlyAfterPresenting() async throws {
    let client = OpenCodeClient.scrollFixture(configuration: .launch())
    let store = ConversationStore(id: "side-question", client: client, hub: EventHub(client: client))
    let window = UIWindow(windowScene: try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
    window.rootViewController = UIHostingController(rootView: SideQuestionHost(store: store))
    window.makeKeyAndVisible()
    defer {
      window.rootViewController?.dismiss(animated: false)
      window.isHidden = true
      window.rootViewController = nil
    }
    var presentingWhenFocused: Bool?
    let observer = NotificationCenter.default.addObserver(
      forName: UITextView.textDidBeginEditingNotification, object: nil, queue: nil
    ) { _ in
      // The sheet's field is the only text view in this window.
      MainActor.assumeIsolated {
        presentingWhenFocused = presentingWhenFocused
          ?? window.rootViewController?.presentedViewController?.isBeingPresented
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    store.sideQuestion = SideQuestionLaunch(text: SideQuestionRequest.quote("Trecho selecionado"))
    await fulfillment(of: [expectation(for: NSPredicate { _, _ in
      window.rootViewController?.presentedViewController != nil
    }, evaluatedWith: nil)], timeout: 5)
    let sheet = try XCTUnwrap(window.rootViewController?.presentedViewController)
    await fulfillment(of: [expectation(for: NSPredicate { _, _ in
      Self.field(in: sheet.view)?.isFirstResponder == true
    }, evaluatedWith: nil)], timeout: 5)
    // Becoming first responder during the transition is what stalled the fullscreen composer.
    XCTAssertEqual(presentingWhenFocused, false)
    let frame = sheet.view.convert(sheet.view.bounds, to: window)
    XCTAssertLessThan(frame.minY, window.bounds.height * 0.2, "A folha abriu na altura média")
    XCTAssertEqual(Self.field(in: sheet.view)?.text, SideQuestionRequest.quote("Trecho selecionado"))
  }

  private static func field(in view: UIView) -> UITextView? {
    if let text = view as? UITextView, text.accessibilityIdentifier == "side-question-composer" { return text }
    return view.subviews.lazy.compactMap { field(in: $0) }.first
  }
}
