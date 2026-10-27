import SwiftUI
import XCTest
@testable import OpenCode
@testable import OpenCodeKit

/// The production "Agentes" views rendered with `ImageRenderer`. The simulator shows one activity per app in the
/// Dynamic Island, so the minimal presentation (shown beside another app's activity) is only visible here. Set
/// `TEST_RUNNER_OPENCODE_CAPTURE_DIR` to keep the PNGs.
@MainActor final class AgentsActivityRenderTests: XCTestCase {
  private func fixture(_ name: String) throws -> (AgentsActivityAttributes, AgentsState) {
    let fixtures = try XCTUnwrap(AgentsActivityFixtures.states[name])
    let attributes = try JSONDecoder().decode(AgentsActivityAttributes.self, from: Data(AgentsActivityFixtures.attributes.utf8))
    return (attributes, try JSONDecoder().decode(AgentsState.self, from: Data(fixtures.utf8)))
  }

  private func render(_ view: some View, size: CGSize, name: String) throws -> UIImage {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
      .environment(\.colorScheme, .dark))
    renderer.scale = 3
    let image = try XCTUnwrap(renderer.uiImage)
    XCTAssertEqual(image.size, size)
    if let directory = ProcessInfo.processInfo.environment["OPENCODE_CAPTURE_DIR"] {
      try image.pngData()?.write(to: URL(fileURLWithPath: directory).appending(path: "ios-\(name).png"))
    }
    return image
  }

  func testMinimalIslandFollowsThePriority() throws {
    let (attributes, mixed) = try fixture("state-mixed")
    var permission = try fixture("state-working").1
    permission.counts.permission = 1
    let cases: [(String, AgentsState, AgentsMinimal)] = [
      ("state-mixed", mixed, .failed(2)), ("state-failed-only", try fixture("state-failed-only").1, .failed(1)),
      ("state-one-question", try fixture("state-one-question").1, .question(1)),
      ("permission", permission, .permission(1)), ("state-working", try fixture("state-working").1, .mascot),
    ]
    for (name, state, expected) in cases {
      XCTAssertEqual(state.minimal, expected, name)
      let island = AgentsMinimalView(attributes: attributes, state: state).frame(width: 25, height: 25).padding(6)
        .background(Circle().fill(.black))
      _ = try render(island, size: CGSize(width: 37, height: 37), name: "v2-\(name)-minimal")
    }
  }

  /// Rendered heights must equal `AgentsLayout`'s computed ones, so the limits checked on them
  /// hold on device, where the system clips instead of proposing its limit.
  func testRenderedHeightsMatchTheFixedLayout() throws {
    for name in ["state-one-question", "state-two-questions", "state-mixed", "state-working", "state-failed-only",
      "state-long-rows"]
    {
      let (attributes, state) = try fixture(name)
      for width in [360.0, 412.0] {
        let measured = try height(AgentsLockScreenView(attributes: attributes, state: state), width)
        XCTAssertEqual(measured, AgentsLayout.lockHeight(state), accuracy: 0.5, "\(name) lock \(width)")
        let island = try height(AgentsIslandExpanded(attributes: attributes, state: state), width - 12)
        XCTAssertEqual(island, AgentsLayout.island(state).height, accuracy: 0.5, "\(name) island \(width)")
        XCTAssertLessThanOrEqual(island, AgentsLayout.islandCeiling)
      }
      let lock = AgentsLayout.lockHeight(state)
      XCTAssertLessThanOrEqual(lock, AgentsLayout.lockLimit, name)
      _ = try render(AgentsLockScreenView(attributes: attributes, state: state)
        .background(attributes.color(.background)), size: CGSize(width: 374, height: lock), name: "v3-\(name)-lock-render")
      _ = try render(AgentsIslandExpanded(attributes: attributes, state: state).padding(.horizontal, 26)
        .frame(height: AgentsLayout.islandRegion, alignment: .top).background(.black),
        size: CGSize(width: 371, height: AgentsLayout.islandRegion), name: "v2-\(name)-expanded-render")
    }
  }

  private func height(_ view: some View, _ width: CGFloat) throws -> CGFloat {
    let renderer = ImageRenderer(content: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
    renderer.scale = 1
    return try XCTUnwrap(renderer.uiImage).size.height
  }

  /// The Apple Watch `.small` card at the smallest Smart Stack size (40 mm, 152 × 69.5 points). Set
  /// `TEST_RUNNER_OPENCODE_WATCH_DIR` to keep `ios-small-<state>.png`.
  func testWatchCardFitsTheSmallestSmartStack() throws {
    for name in ["state-mixed", "state-working", "state-one-question", "state-failed-only"] {
      var (attributes, state) = try fixture(name)
      // Like the launch fixture: keep "há 3 min" whenever the test runs.
      let shift = (Date.now.timeIntervalSince1970 * 1000).rounded() - state.updatedAt
      for index in state.attention.indices { state.attention[index].since += shift }
      let card = AgentsWatchView(attributes: attributes, state: state)
      XCTAssertLessThanOrEqual(try height(card, 152), 69.5, name)
      let renderer = ImageRenderer(content: card.padding(8).frame(width: 168, height: 85)
        .background(RoundedRectangle(cornerRadius: 18).fill(attributes.color(.surface)))
        .environment(\.colorScheme, .dark))
      renderer.scale = 3
      let image = try XCTUnwrap(renderer.uiImage)
      if let directory = ProcessInfo.processInfo.environment["OPENCODE_WATCH_DIR"],
        ["state-mixed", "state-working"].contains(name)
      {
        try image.pngData()?.write(to: URL(fileURLWithPath: directory).appending(path: "ios-small-\(name).png"))
      }
    }
  }

  func testServerKeysAreStablePerServerAndSeparateForLaunchOverrides() throws {
    let suite = "AgentsActivityRenderTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let saved = ServerStore(defaults: defaults)
    XCTAssertEqual(AgentsActivityAgent.serverKey(saved), "builtin")
    let sandbox = ServerStore(defaults: defaults,
      launchOverride: ServerConfiguration(url: URL(string: "http://127.0.0.1:4177")!, password: nil))
    XCTAssertEqual(AgentsActivityAgent.serverKey(sandbox), "launch-127.0.0.1-4177")
    XCTAssertEqual(AgentsActivityAgent.server(for: "launch-127.0.0.1-4177", in: sandbox)?.id, "builtin")
    XCTAssertNil(AgentsActivityAgent.server(for: "builtin", in: sandbox))
  }
}
