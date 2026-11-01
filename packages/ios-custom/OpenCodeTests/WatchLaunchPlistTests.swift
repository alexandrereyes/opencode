import XCTest
@testable import OpenCode
@testable import OpenCodeKit

/// The watch app embedded in the iPhone app, as built (rev. 2026-11-01): watchOS opens it from a Live Activity in the
/// Smart Stack only when its Info.plist names that `ActivityAttributes` type exactly, otherwise it shows the card
/// full screen with "open on iPhone". Only the agents Live Activity is listed; the voice one keeps opening the iPhone.
final class WatchLaunchPlistTests: XCTestCase {
  func testEmbeddedWatchAppOpensFromTheAgentsLiveActivityOnly() throws {
    let url = Bundle.main.bundleURL.appendingPathComponent("Watch/OpenCodeWatch.app/Info.plist")
    let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any], "no watch app at \(url.path)")
    let types = plist["WKSupportsLiveActivityLaunchAttributeTypes"] as? [String]
    XCTAssertEqual(types, [String(describing: AgentsActivityAttributes.self)])
    XCTAssertEqual(types, ["AgentsActivityAttributes"])
    XCTAssertFalse(types?.contains(String(describing: VoiceActivityAttributes.self)) ?? true)
    // The complications' `widgetURL` scheme.
    let schemes = (plist["CFBundleURLTypes"] as? [[String: Any]])?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    XCTAssertEqual(schemes, [WatchLaunch.scheme])
  }
}
