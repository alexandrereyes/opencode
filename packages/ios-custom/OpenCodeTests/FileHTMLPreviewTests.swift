import UIKit
import WebKit
import XCTest
@testable import OpenCode

@MainActor final class FileHTMLPreviewTests: XCTestCase {
  func testConfigurationKeepsThePageAwayFromTheAppAndItsCredential() async throws {
    let configuration = HTMLPageView.configuration()
    XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    XCTAssertTrue(configuration.userContentController.userScripts.isEmpty)
    XCTAssertTrue(configuration.defaultWebpagePreferences.allowsContentJavaScript)
    XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)

    var terminated = 0
    var opened: [URL] = []
    let coordinator = HTMLPageView.Coordinator(terminated: { terminated += 1 })
    coordinator.open = { opened.append($0) }
    let view = WKWebView(frame: .zero, configuration: configuration)
    // A crashed web content process becomes the retry state instead of a blank page.
    coordinator.webViewWebContentProcessDidTerminate(view)
    XCTAssertEqual(terminated, 1)

    // Any HTTP authentication challenge is refused; only server trust keeps the system's evaluation.
    for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault] {
      let space = URLProtectionSpace(host: "127.0.0.1", port: 4096, protocol: "http", realm: "opencode", authenticationMethod: method)
      let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
        failureResponse: nil, error: nil, sender: ChallengeSender())
      let answer = await coordinator.webView(view, didReceive: challenge)
      XCTAssertEqual(answer.0, .cancelAuthenticationChallenge, method)
      XCTAssertNil(answer.1)
    }
    let trust = URLProtectionSpace(host: "example.com", port: 443, protocol: "https", realm: nil,
      authenticationMethod: NSURLAuthenticationMethodServerTrust)
    let answer = await coordinator.webView(view, didReceive: URLAuthenticationChallenge(protectionSpace: trust,
      proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender()))
    XCTAssertEqual(answer.0, .performDefaultHandling)
    XCTAssertTrue(opened.isEmpty)
  }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
  func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
  func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
  func cancel(_ challenge: URLAuthenticationChallenge) {}
}
