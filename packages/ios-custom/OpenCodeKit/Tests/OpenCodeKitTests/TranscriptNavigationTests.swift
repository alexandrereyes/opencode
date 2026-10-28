import Testing

@testable import OpenCodeKit

@Suite struct TranscriptNavigationTests {
  /// The history control, a prompt and its answer in three blocks, then a second prompt and a short answer.
  private func conversation() -> (TranscriptGeometry, [TranscriptItemIdentity]) {
    let items: [TranscriptItemIdentity] = [
      .init(id: "older"),
      .init(id: "prompt:u1", message: "u1", sticky: true),
      .init(id: "text:p1:0", partID: "p1", message: "a1"),
      .init(id: "text:p1:1", partID: "p1", message: "a1"),
      .init(id: "footer:a1", message: "a1"),
      .init(id: "prompt:u2", message: "u2", sticky: true),
      .init(id: "text:p2:0", partID: "p2", message: "a2"),
    ]
    var geometry = TranscriptGeometry(topPadding: 16, bottomPadding: 16)
    geometry.replace([
      .init(id: "older", gap: 0, height: 32),
      .init(id: "prompt:u1", gap: 0, height: 80, sticky: true),
      .init(id: "text:p1:0", gap: 10, height: 400),
      .init(id: "text:p1:1", gap: 16, height: 300),
      .init(id: "footer:a1", gap: 16, height: 20),
      .init(id: "prompt:u2", gap: 10, height: 80, sticky: true),
      .init(id: "text:p2:0", gap: 10, height: 100),
    ])
    return (geometry, items)
  }

  @Test func latestIsTheEndOrTheSpacerPromptAtTheTop() {
    var (geometry, _) = conversation()
    #expect(geometry.tops == [16, 48, 138, 554, 870, 900, 990])
    #expect(geometry.contentEnd == 1106)
    #expect(geometry.latestOffset(viewport: 600, maximum: 506) == 506)
    // A just-sent prompt rises to the top: the trailing space lets the content end below it.
    geometry.spacerPrompt = "prompt:u2"
    #expect(geometry.latestOffset(viewport: 600, maximum: 900) == 900)
    #expect(geometry.latestOffset(viewport: 2000, maximum: 0) == 0, "never below zero or past the maximum")
  }

  @Test func theAnchorSkipsTheHistoryControlAndUnmeasuredRowsAboveShownOnes() {
    let (geometry, _) = conversation()
    let measured = [true, true, true, true, true, true, true]
    #expect(geometry.stableAnchor(visibleTop: 0, viewport: 600, measured: measured, control: "older")
      == .init(id: "prompt:u1", screenY: 48), "older pages land below the control, never on it")
    // Scrolled into a block that was never measured, with a measured one below it on screen: the measured one
    // stays still while the other is measured.
    var unmeasured = measured
    unmeasured[2] = false
    let anchor = geometry.stableAnchor(visibleTop: 200, viewport: 600, measured: unmeasured)
    #expect(anchor == .init(id: "text:p1:1", screenY: 554 - 200))
    #expect(geometry.stableAnchor(visibleTop: 200, viewport: 600, measured: measured)?.id == "text:p1:0")
  }

  @Test func theAnchorContinuesInWhatReplacedItsItem() {
    let (geometry, items) = conversation()
    let anchor = TranscriptGeometry.Anchor(id: "text:p1:1", screenY: 40)
    #expect(geometry.continued(anchor, from: items, to: items) == anchor)
    // A newer parse split the part differently: its first new block keeps the place.
    var reparsed = items
    reparsed[2] = .init(id: "text:p1:7", partID: "p1", message: "a1")
    reparsed[3] = .init(id: "text:p1:8", partID: "p1", message: "a1")
    #expect(geometry.continued(anchor, from: items, to: reparsed) == .init(id: "text:p1:7", screenY: 40))
    // The part is gone but its message remains.
    var message = items
    message.removeSubrange(2...3)
    #expect(geometry.continued(anchor, from: items, to: message) == .init(id: "footer:a1", screenY: 40))
    // Neither remains: the next survivor, at its own screen position.
    let rest = [items[0], items[1], items[5], items[6]]
    #expect(geometry.continued(anchor, from: items, to: rest) == .init(id: "prompt:u2", screenY: 40 + 900 - 554))
    #expect(geometry.continued(.init(id: "gone", screenY: 0), from: items, to: rest) == nil)
  }

  @Test func ownersStartEachMessageWithItsPadding() {
    let (geometry, items) = conversation()
    let owners = TranscriptGeometry.owners(items)
    #expect(owners.map(\.start) == [0, 1, 2, 2, 2, 5, 6])
    #expect(owners.map(\.inset) == [0, 0, 10, 10, 10, 0, 10])
    #expect(geometry.messageTop(3, owners: owners) == 138 - 10)
    #expect(geometry.messageTop(5, owners: owners) == 900)
  }

  @Test func followingStopsWhenTheReaderScrollsAndResumesAtTheEnd() {
    var follow = TranscriptFollow()
    follow.opened(atEnd: true)
    #expect(follow.keepsLatest)
    follow.began()
    #expect(!follow.following && !follow.keepsLatest)
    follow.settled(distance: 300)
    #expect(!follow.following, "settling above the end reads in place")
    follow.began()
    follow.settled(distance: 1)
    #expect(follow.keepsLatest, "scrolling back to the end follows again")
    follow.navigated(toLatest: false)
    #expect(!follow.following, "search or a quote elsewhere stops it")
    follow.navigated(toLatest: true)
    #expect(follow.following)
  }

  @Test func keysPageByTheViewportLessALine() {
    #expect(TranscriptScrollKey.pageDown.target(visibleTop: 1000, viewport: 700, latest: 5000) == 1640)
    #expect(TranscriptScrollKey.pageUp.target(visibleTop: 300, viewport: 700, latest: 5000) == 0)
    #expect(TranscriptScrollKey.pageDown.target(visibleTop: 4900, viewport: 700, latest: 5000) == 5000)
    #expect(TranscriptScrollKey.top.target(visibleTop: 4900, viewport: 700, latest: 5000) == 0)
    #expect(TranscriptScrollKey.latest.target(visibleTop: 10, viewport: 700, latest: 5000) == 5000)
    #expect(TranscriptScrollKey.lineDown.target(visibleTop: 10, viewport: 700, latest: 5000) == 50)
  }
}
