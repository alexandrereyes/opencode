import Testing

@testable import OpenCodeKit

@Suite struct TranscriptGeometryTests {
  /// Two turns: a prompt and two rows each, with gaps.
  private func turns() -> TranscriptGeometry {
    var geometry = TranscriptGeometry(topPadding: 4, bottomPadding: 12)
    geometry.replace([
      .init(id: "p1", gap: 0, height: 60, sticky: true),
      .init(id: "a", gap: 10, height: 200),
      .init(id: "b", gap: 16, height: 300),
      .init(id: "p2", gap: 20, height: 80, sticky: true),
      .init(id: "c", gap: 10, height: 500),
    ])
    return geometry
  }

  @Test func positionsIncludeGapsAndShiftAfterAHeightChange() {
    var geometry = turns()
    #expect(geometry.tops == [4, 74, 290, 610, 700])
    #expect(geometry.contentEnd == 1212)
    #expect(geometry.setHeight(250, at: 1) == 50)
    #expect(geometry.tops == [4, 74, 340, 660, 750])
    #expect(geometry.firstIndex(below: 330) == 2)
    #expect(geometry.firstIndex(below: 2000) == 5)
  }

  @Test func promptPinsWhileItsSectionCrossesTheTopAndIsPushedByTheNext() {
    let geometry = turns()
    #expect(geometry.pinned(visibleTop: 0) == nil, "inline at the top of the content")
    #expect(geometry.pinned(visibleTop: 4) == .init(index: 0, y: 4), "at the top edge it is already pinned")
    #expect(geometry.anchor(visibleTop: 4) == .init(id: "a", screenY: 70), "and the turn below it is the place")
    #expect(geometry.pinned(visibleTop: 100) == .init(index: 0, y: 100))
    #expect(geometry.usableTop(visibleTop: 100) == 60)
    // The next prompt starts at 610: the first one may not overlap it.
    #expect(geometry.pinned(visibleTop: 580) == .init(index: 0, y: 550))
    #expect(geometry.usableTop(visibleTop: 580) == 30)
    #expect(geometry.pinned(visibleTop: 650) == .init(index: 3, y: 650))
  }

  @Test func anchorIsTheItemBelowThePinnedPromptOrTheNextAfterAGap() {
    let geometry = turns()
    // Line at 160 (100 + pinned 60) falls inside "a".
    #expect(geometry.anchor(visibleTop: 100) == .init(id: "a", screenY: -26))
    // Line at 277: in the gap before "b" (274...290), so "b" is the anchor, still below the line.
    #expect(geometry.anchor(visibleTop: 217) == .init(id: "b", screenY: 73))
    // At the very top nothing is pinned and the first prompt itself is the reader's place.
    #expect(geometry.anchor(visibleTop: 0) == .init(id: "p1", screenY: 4))
  }

  @Test func restoringAnAnchorKeepsItsScreenPositionAcrossInsertionsAndResizes() {
    var geometry = turns()
    let anchor = geometry.anchor(visibleTop: 300)!
    var entries = geometry.entries
    entries.insert(.init(id: "older", gap: 0, height: 900, sticky: true), at: 0)
    geometry.replace(entries)
    geometry.setHeight(260, at: 2)
    let top = geometry.visibleTop(for: anchor)!
    #expect(geometry.anchor(visibleTop: top) == anchor)
  }

  @Test func spacerLetsThePromptReachTheTopAndShrinksAsTheAnswerGrows() {
    var geometry = turns()
    geometry.spacerPrompt = "p2"
    // Prompt at 610, content ends at 1212: a 900-point viewport needs 298 more points.
    #expect(geometry.spacer(viewport: 900) == 298)
    #expect(geometry.contentHeight(viewport: 900) - 900 == 610)
    geometry.setHeight(700, at: 4)
    #expect(geometry.spacer(viewport: 900) == 98)
    #expect(geometry.contentHeight(viewport: 900) - 900 == 610, "growth inside the spacer moves nothing")
    geometry.setHeight(1200, at: 4)
    #expect(geometry.spacer(viewport: 900) == 0)
    geometry.spacerPrompt = nil
    #expect(geometry.spacer(viewport: 900) == 0)
  }
}
