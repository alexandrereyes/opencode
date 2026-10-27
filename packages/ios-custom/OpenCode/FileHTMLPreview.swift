import OpenCodeKit
import SwiftUI
import UIKit.UIGestureRecognizerSubclass
import WebKit

/// An HTML file in one of two modes, chosen anew for every opened file:
///
/// - **Local files** (default): the page and the files next to it (its folder and subfolders, and the Session
///   directory when the page is inside it) come from `opencode-preview://<token>/…` through `HTMLAssetHandler`,
///   which reads them with the app's credential. The network is blocked by a content rule list and a CSP, so a
///   script that reads local files has nowhere to send them.
/// - **Internet**: the web app's sandboxed-iframe behaviour, the page alone with scripts and the network.
///
/// Both keep the page away from the app and its server credential: a non-persistent data store, no script
/// message handlers, never a `file:` base URL, every authentication challenge refused, and only a link the person
/// tapped leaves for Safari.
struct FileHTMLPreview: View {
  @Environment(\.appTheme) private var theme
  let file: URL
  let path: String
  let context: ConversationImageContext
  @Binding var internet: Bool
  @State private var page: Data?
  @State private var scope: HTMLPreviewScope
  @State private var controller = HTMLPageController()
  @State private var terminated = false
  @State private var attempt = 0
  init(file: URL, path: String, context: ConversationImageContext, internet: Binding<Bool>) {
    self.file = file
    self.path = path
    self.context = context
    _internet = internet
    _scope = State(initialValue: HTMLPreviewScope(file: path, sessionDirectory: context.directory))
  }
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
      } else if let page {
        HTMLPageView(page: page, scope: internet ? nil : scope, client: context.client, controller: controller,
          terminated: { terminated = true })
          .id("\(attempt)-\(internet)")
          .accessibilityIdentifier("file-html")
          .overlay(alignment: .topLeading) {
            if controller.canGoBack {
              Button("Página anterior", systemImage: "chevron.backward") { controller.goBack() }
                .labelStyle(.iconOnly).font(.body.weight(.semibold)).frame(width: 40, height: 40)
                .buttonStyle(.glass).buttonBorderShape(.circle).padding(10)
                .accessibilityIdentifier("file-html-back")
            }
          }
          .overlay(alignment: .bottom) { mode }
      } else {
        ProgressView("Carregando página…")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: file) {
      page = await Task.detached(priority: .userInitiated) { (try? Data(contentsOf: file)) ?? Data() }.value
    }
  }

  private var mode: some View {
    HStack(spacing: 10) {
      Label(internet ? "Internet, sem arquivos locais" : "Arquivos locais, sem internet",
        systemImage: internet ? "globe" : "folder")
        .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(theme.color(.textSecondary))
        .accessibilityElement(children: .combine).accessibilityIdentifier("file-html-mode")
      Button(internet ? "Usar arquivos locais" : "Permitir internet") { internet.toggle() }
        .font(.caption.weight(.semibold)).accessibilityIdentifier("file-html-internet")
        .accessibilityHint(internet ? "Recarrega a página com os arquivos ao lado dela e sem internet"
          : "Recarrega a página com internet e sem os arquivos ao lado dela")
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    // Over the page's white canvas a glass capsule would lose its contrast.
    .background(theme.color(.background), in: Capsule())
    .overlay { Capsule().strokeBorder(theme.color(.border)) }
    .padding(.bottom, 8)
  }
}

@MainActor @Observable final class HTMLPageController {
  var canGoBack = false
  weak var view: WKWebView?
  func goBack() { view?.goBack() }
}

struct HTMLPageView: UIViewRepresentable {
  let page: Data
  /// Local files when set; the internet and the page alone otherwise.
  let scope: HTMLPreviewScope?
  let client: OpenCodeClient
  var controller = HTMLPageController()
  let terminated: () -> Void

  static func configuration(scope: HTMLPreviewScope? = nil, handler: HTMLAssetHandler? = nil) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.allowsInlineMediaPlayback = true
    configuration.dataDetectorTypes = []
    if let handler { configuration.setURLSchemeHandler(handler, forURLScheme: HTMLPreviewScope.scheme) }
    if scope != nil {
      // Peer connections reach STUN/TURN servers outside the content rule list and the CSP.
      configuration.userContentController.addUserScript(WKUserScript(source: """
        for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCIceCandidate"]) {
          try { Object.defineProperty(window, name, { value: undefined, configurable: false, writable: false }) } catch {}
        }
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    return configuration
  }

  func makeCoordinator() -> Coordinator { Coordinator(terminated: terminated, scope: scope) }

  func makeUIView(context: Context) -> WKWebView {
    let handler = scope.map { HTMLAssetHandler(scope: $0, client: client, page: page) }
    context.coordinator.handler = handler
    let view = WKWebView(frame: .zero, configuration: Self.configuration(scope: scope, handler: handler))
    view.navigationDelegate = context.coordinator
    view.uiDelegate = context.coordinator
    // A link preview's "Open" would navigate long after the touch.
    view.allowsLinkPreview = false
    // Pages are written for a browser's white canvas; a transparent view would put dark text on the dark theme.
    view.backgroundColor = .white
    view.scrollView.backgroundColor = .white
    // Room for the mode bar at the end of the page.
    view.scrollView.contentInset.bottom = 56
    let recorder = TouchRecorder()
    recorder.touched = { [weak coordinator = context.coordinator] in coordinator?.touched = .now }
    view.addGestureRecognizer(recorder)
    controller.view = view
    context.coordinator.observation = view.observe(\.canGoBack, options: [.initial, .new]) { [controller] view, _ in
      MainActor.assumeIsolated { controller.canGoBack = view.canGoBack }
    }
    guard let scope else {
      view.loadHTMLString(String(decoding: page, as: UTF8.self), baseURL: nil)
      return view
    }
    // Nothing loads before the network is blocked.
    context.coordinator.loading = Task { @MainActor [weak view, weak coordinator = context.coordinator] in
      // Without the rules the page is not loaded at all; the retry state offers to try again.
      guard let rules = await HTMLOfflineRules.shared.list() else { coordinator?.terminated(); return }
      guard let view else { return }
      view.configuration.userContentController.add(rules)
      view.load(URLRequest(url: scope.pageURL))
    }
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {
    context.coordinator.terminated = terminated
  }

  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.loading?.cancel()
    coordinator.observation = nil
    coordinator.handler?.cancelAll()
    view.stopLoading()
    view.navigationDelegate = nil
    view.uiDelegate = nil
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var terminated: () -> Void
    let scope: HTMLPreviewScope?
    var handler: HTMLAssetHandler?
    var loading: Task<Void, Never>?
    var observation: NSKeyValueObservation?
    var touched = Date.distantPast
    private var started = false
    var open: (URL) -> Void = { UIApplication.shared.open($0) }
    init(terminated: @escaping () -> Void, scope: HTMLPreviewScope? = nil) {
      self.terminated = terminated
      self.scope = scope
    }

    func decide(_ action: WKNavigationAction, current: URL? = nil) -> HTMLPreviewPolicy.Decision {
      let mainFrame = action.targetFrame?.isMainFrame ?? true
      let decision = HTMLPreviewPolicy.decide(action.request.url, mainFrame: mainFrame,
        linkActivated: action.navigationType == .linkActivated,
        recentTouch: Date.now.timeIntervalSince(touched) < HTMLPreviewPolicy.touchWindow,
        scope: scope, current: current, initial: mainFrame && !started,
        backForward: action.navigationType == .backForward)
      if mainFrame, decision == .allow { started = true }
      return decision
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
      -> WKNavigationActionPolicy {
      switch decide(navigationAction, current: webView.url) {
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
      if case .openExternally(let url) = decide(navigationAction, current: webView.url) {
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

/// Serves `opencode-preview://<token>/…` for one opened page: its own bytes, then the files of its scope read
/// with the app's credential (the page never sees it). Requests outside the scope or that fail get a 404.
/// Video and audio need byte ranges, which are not served.
@MainActor final class HTMLAssetHandler: NSObject, WKURLSchemeHandler {
  let scope: HTMLPreviewScope
  let client: OpenCodeClient
  let page: Data
  private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  /// Repeated loads of one page (a stylesheet in every report page) are read once while it stays open.
  private var cache: [String: Data] = [:]
  private var cached = 0
  private static let cacheLimit = 64 * 1024 * 1024
  init(scope: HTMLPreviewScope, client: OpenCodeClient, page: Data) {
    self.scope = scope
    self.client = client
    self.page = page
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url, let target = scope.resolve(url) else {
      return Self.respond(task, status: 404, data: Data(), path: "")
    }
    let path = target.root + "/" + target.relative
    if path == scope.file { return Self.respond(task, status: 200, data: page, path: path) }
    if let data = cache[path] { return Self.respond(task, status: 200, data: data, path: path) }
    let id = ObjectIdentifier(task)
    tasks[id] = Task { [weak self, client] in
      let data = try? await client.previewResource(target.relative, root: target.root)
      // A stopped task must not be answered.
      guard let self, tasks.removeValue(forKey: id) != nil else { return }
      guard let data else { return Self.respond(task, status: 404, data: Data(), path: path) }
      if cached + data.count <= Self.cacheLimit {
        cache[path] = data
        cached += data.count
      }
      Self.respond(task, status: 200, data: data, path: path)
    }
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
    tasks.removeValue(forKey: ObjectIdentifier(task))?.cancel()
  }

  func cancelAll() {
    tasks.values.forEach { $0.cancel() }
    tasks = [:]
    cache = [:]
    cached = 0
  }

  private static func respond(_ task: any WKURLSchemeTask, status: Int, data: Data, path: String) {
    let mime = HTMLPreviewScope.mime(path)
    let type = mime.hasPrefix("text/") || mime == "application/json" ? mime + "; charset=utf-8" : mime
    let response = HTTPURLResponse(url: task.request.url ?? URL(string: "\(HTMLPreviewScope.scheme)://invalid")!,
      statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
        "Content-Type": type, "Content-Length": String(data.count),
        "Content-Security-Policy": HTMLPreviewScope.contentSecurityPolicy,
        "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store",
      ])!
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }
}

/// Blocks every web load of a local-files page: content rules apply to images, fetch, beacons, prefetch,
/// web sockets and frames alike, before any request leaves the device.
@MainActor final class HTMLOfflineRules {
  static let shared = HTMLOfflineRules()
  private var compiled: Task<WKContentRuleList?, Never>?
  func list() async -> WKContentRuleList? {
    if let compiled { return await compiled.value }
    let task = Task { @MainActor in
      try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "opencode-html-preview-offline",
        encodedContentRuleList: """
          [{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
           {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},
           {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}}]
          """)
    }
    compiled = task
    return await task.value
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
