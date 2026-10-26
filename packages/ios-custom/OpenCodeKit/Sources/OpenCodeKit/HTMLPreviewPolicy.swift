import Foundation

/// What the HTML preview does with a navigation. The page is isolated: it is loaded once from a string with no
/// base URL, and only a link the person actually tapped leaves it, in the system browser.
public enum HTMLPreviewPolicy {
  public enum Decision: Sendable, Equatable {
    case allow
    case cancel
    case openExternally(URL)
  }

  /// A tap counts as the link's cause only within this window; script clicks without a touch do not.
  public static let touchWindow: TimeInterval = 1.5
  static let external: Set<String> = ["http", "https", "mailto", "tel", "sms"]

  /// `linkActivated` is WebKit's navigation type for a followed link; `recentTouch` says the person touched the
  /// page just before. Subframes may load web content (the network is on, as in the web app's sandboxed iframe).
  public static func decide(_ url: URL?, mainFrame: Bool, linkActivated: Bool, recentTouch: Bool) -> Decision {
    guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
    // The document itself (also its in-page `#anchors`) and `srcdoc` frames.
    if scheme == "about" {
      let page = url.absoluteString == "about:blank" || url.absoluteString.hasPrefix("about:blank#")
      return page || !mainFrame && url.absoluteString == "about:srcdoc" ? .allow : .cancel
    }
    if linkActivated, recentTouch, external.contains(scheme) { return .openExternally(url) }
    if !mainFrame, ["http", "https", "data", "blob"].contains(scheme), !linkActivated { return .allow }
    return .cancel
  }
}
