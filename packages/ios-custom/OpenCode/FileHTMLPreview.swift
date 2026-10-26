import OpenCodeKit
import SwiftUI
import UIKit.UIGestureRecognizerSubclass
import WebKit

/// An HTML file rendered like the web app's sandboxed iframe: scripts and the network work, files next to it do
/// not. The page is isolated from the app and its server credential: a non-persistent data store, no script
/// message handlers, no base URL (so no `file:` access to other previews), every authentication challenge
/// refused, and only a link the person tapped leaves it, in the system browser.
struct FileHTMLPreview: View {
  @Environment(\.appTheme) private var theme
  let file: URL
  @State private var html: String?
  @State private var terminated = false
  @State private var attempt = 0
  var body: some View {
    Group {
      if terminated {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle").font(.largeTitle)
          Text("A prévia da página parou de responder.").multilineTextAlignment(.center)
          Button("Tentar novamente") {
            terminated = false
            attempt += 1
          }
        }
        .padding(24).foregroundStyle(theme.color(.textSecondary))
        .accessibilityElement(children: .contain).accessibilityIdentifier("file-html-terminated")
      } else if let html {
        HTMLPageView(html: html, terminated: { terminated = true }).id(attempt)
          .accessibilityIdentifier("file-html")
      } else {
        ProgressView("Carregando página…")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: file) {
      html = await Task.detached(priority: .userInitiated) {
        (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } ?? ""
      }.value
    }
  }
}

struct HTMLPageView: UIViewRepresentable {
  let html: String
  let terminated: () -> Void

  static func configuration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.allowsInlineMediaPlayback = true
    configuration.dataDetectorTypes = []
    return configuration
  }

  func makeCoordinator() -> Coordinator { Coordinator(terminated: terminated) }

  func makeUIView(context: Context) -> WKWebView {
    let view = WKWebView(frame: .zero, configuration: Self.configuration())
    view.navigationDelegate = context.coordinator
    view.uiDelegate = context.coordinator
    // A link preview's "Open" would navigate long after the touch.
    view.allowsLinkPreview = false
    // Pages are written for a browser's white canvas; a transparent view would put dark text on the dark theme.
    view.backgroundColor = .white
    view.scrollView.backgroundColor = .white
    let recorder = TouchRecorder()
    recorder.touched = { [weak coordinator = context.coordinator] in coordinator?.touched = .now }
    view.addGestureRecognizer(recorder)
    view.loadHTMLString(html, baseURL: nil)
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {
    context.coordinator.terminated = terminated
  }

  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    view.navigationDelegate = nil
    view.uiDelegate = nil
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var terminated: () -> Void
    var touched = Date.distantPast
    var open: (URL) -> Void = { UIApplication.shared.open($0) }
    init(terminated: @escaping () -> Void) { self.terminated = terminated }

    func decide(_ action: WKNavigationAction) -> HTMLPreviewPolicy.Decision {
      HTMLPreviewPolicy.decide(action.request.url, mainFrame: action.targetFrame?.isMainFrame ?? true,
        linkActivated: action.navigationType == .linkActivated,
        recentTouch: Date.now.timeIntervalSince(touched) < HTMLPreviewPolicy.touchWindow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
      -> WKNavigationActionPolicy {
      switch decide(navigationAction) {
      case .allow: return .allow
      case .cancel: return .cancel
      case .openExternally(let url):
        touched = .distantPast
        open(url)
        return .cancel
      }
    }

    /// `target="_blank"` and `window.open` never create a web view; a tapped link still opens outside.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      if case .openExternally(let url) = decide(navigationAction) {
        touched = .distantPast
        open(url)
      }
      return nil
    }

    /// The page never answers an HTTP authentication challenge, so no credential can reach a request it makes.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async
      -> (URLSession.AuthChallengeDisposition, URLCredential?) {
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { terminated() }
  }
}

/// Records that a touch began on the page without taking part in its gestures.
private final class TouchRecorder: UIGestureRecognizer {
  var touched: (() -> Void)?
  override init(target: Any? = nil, action: Selector? = nil) {
    super.init(target: target, action: action)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    touched?()
    state = .failed
  }
}
