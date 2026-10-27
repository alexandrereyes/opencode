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
  /// page just before. With the internet allowed (no `scope`), subframes may load web content, as in the web
  /// app's sandboxed iframe. With local files (`scope`), only that scope's own origin loads: the first page,
  /// frames, tapped links to its other HTML pages, history steps and same-page `#` changes (hash routing).
  public static func decide(_ url: URL?, mainFrame: Bool, linkActivated: Bool, recentTouch: Bool,
    scope: HTMLPreviewScope? = nil, current: URL? = nil, initial: Bool = false, backForward: Bool = false) -> Decision {
    guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
    // The document itself (also its in-page `#anchors`) and `srcdoc` frames.
    if scheme == "about" {
      let page = url.absoluteString == "about:blank" || url.absoluteString.hasPrefix("about:blank#")
      return page || !mainFrame && url.absoluteString == "about:srcdoc" ? .allow : .cancel
    }
    if scheme == HTMLPreviewScope.scheme {
      guard let scope, scope.resolve(url) != nil else { return .cancel }
      if !mainFrame || initial && url == scope.pageURL || backForward { return .allow }
      if let current, Self.withoutFragment(current) == Self.withoutFragment(url) { return .allow }
      return linkActivated && recentTouch && scope.isPage(url) ? .allow : .cancel
    }
    if linkActivated, recentTouch, external.contains(scheme) { return .openExternally(url) }
    // Local mode keeps frames on the page's own origin: a `data:` frame would escape its script hardening.
    let frames = scope == nil ? ["http", "https", "data", "blob"] : []
    if !mainFrame, frames.contains(scheme), !linkActivated { return .allow }
    return .cancel
  }

  static func withoutFragment(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    return components?.string ?? url.absoluteString
  }
}
