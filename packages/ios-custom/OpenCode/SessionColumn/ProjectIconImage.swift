import OpenCodeKit
import SwiftUI
import WebKit

/// A project's own icon at text size; blank until the first decode of its revision.
struct ProjectIconImage: View {
  let icon: ProjectIcon
  @ScaledMetric(relativeTo: .subheadline) private var side = 18.0
  @State private var image: CGImage?

  var body: some View {
    ZStack {
      if let image = ProjectIconCache.shared.cached(icon) ?? image {
        Image(decorative: image, scale: 1).resizable().interpolation(.high)
      }
    }
    .frame(width: side, height: side)
    .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
    .task(id: icon.key) {
      image = nil
      image = await ProjectIconCache.shared.image(icon) { await ProjectIconRenderer.render($0, pixels: $1) }
    }
  }
}

/// Rasterizes an SVG icon to PNG through an `<img>` in a throwaway web view: no JavaScript, no network and only
/// `data:` images, like the Mermaid diagrams. WebKit paints only views in a window, so it sits behind the app's views.
@MainActor enum ProjectIconRenderer {
  static func render(_ svg: Data, pixels: Int) async -> Data? {
    guard
      let window = UIApplication.shared.connectedScenes.lazy.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    else { return nil }
    // WebKit zooms pages narrower than a phone's minimum layout width, so the page is phone-wide and the snapshot
    // scales it down.
    let page = 320.0
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(
      frame: CGRect(x: 0, y: window.safeAreaInsets.top, width: page, height: page), configuration: configuration)
    view.isOpaque = false
    view.backgroundColor = .clear
    view.scrollView.backgroundColor = .clear
    // Below the status bar and without safe-area insets, so nothing shifts the image.
    view.scrollView.contentInsetAdjustmentBehavior = .never
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    let loader = Loader()
    view.navigationDelegate = loader
    window.insertSubview(view, at: 0)
    defer {
      view.stopLoading()
      view.navigationDelegate = nil
      view.removeFromSuperview()
    }
    view.loadHTMLString("""
      <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:;"><style>html,body{margin:0;width:100%;height:100%;background:transparent}img{display:block;width:100%;height:100%;object-fit:contain}</style></head><body><img src="data:image/svg+xml;base64,\(svg.base64EncodedString())"></body></html>
      """, baseURL: nil)
    guard await loader.finished() else { return nil }
    let snapshot = WKSnapshotConfiguration()
    snapshot.rect = view.bounds
    snapshot.snapshotWidth = NSNumber(value: Double(pixels) / window.traitCollection.displayScale)
    return try? await view.takeSnapshot(configuration: snapshot).pngData()
  }

  @MainActor private final class Loader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func finished() async -> Bool {
      if let result { return result }
      return await withCheckedContinuation { continuation in
        self.continuation = continuation
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(5))
          self.finish(false)
        }
      }
    }
    private func finish(_ value: Bool) {
      guard result == nil else { return }
      result = value
      continuation?.resume(returning: value)
      continuation = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
      finish(false)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(false) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
      navigationAction.request.url?.scheme == "about" ? .allow : .cancel
    }
  }
}
