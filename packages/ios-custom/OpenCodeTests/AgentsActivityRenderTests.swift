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
      _ = try render(island, size: CGSize(width: 37, height: 37), name: "\(name)-minimal")
    }
  }

  func testLockScreenAndExpandedFitTheirSystemBounds() throws {
    for name in ["state-one-question", "state-two-questions", "state-mixed", "state-working", "state-failed-only"] {
      let (attributes, state) = try fixture(name)
      // The Lock Screen clips a Live Activity at 160 points; `ViewThatFits` needs one density within it.
      let heights = AgentsDensity.allCases.map { density in
        ImageRenderer(content: AgentsLockScreenLayout(attributes: attributes, state: state, density: density)
          .frame(width: 374).fixedSize(horizontal: false, vertical: true)).uiImage?.size.height ?? .infinity
      }
      XCTAssertLessThanOrEqual(heights.min() ?? .infinity, 160, "\(name) \(heights)")
      if name == "state-working" { XCTAssertLessThanOrEqual(heights[0], 160, "the mock's layout fits") }
      _ = try render(AgentsLockScreenView(attributes: attributes, state: state)
        .background(attributes.color(.background)), size: CGSize(width: 374, height: 160), name: "\(name)-lock-render")
      _ = try render(AgentsIslandExpanded(attributes: attributes, state: state).padding(.horizontal, 20)
        .background(.black), size: CGSize(width: 371, height: 150), name: "\(name)-expanded-render")
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
