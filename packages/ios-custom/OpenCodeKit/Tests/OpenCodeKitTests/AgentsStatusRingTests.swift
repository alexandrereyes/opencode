import Foundation
import Testing

@testable import OpenCodeKit

/// The state ring shared by the Live Activity, its watch card, the complications and the watch Painel.
@Suite struct AgentsStatusRingTests {
  private func ring(working: Int = 0, question: Int = 0, permission: Int = 0, failed: Int = 0, unread: Int? = 0,
    idle: Int = 0) -> AgentsStatusRing
  {
    AgentsStatusRing(counts: .init(working: working, question: question, permission: permission, failed: failed,
      idle: idle, unread: unread))
  }

  private func shares(_ ring: AgentsStatusRing) -> [Double] {
    ring.segments.map { Double($0.count) / Double(ring.total) }
  }

  @Test func onlyWorkingIsGreenWithTheActiveCount() {
    let ring = ring(working: 3)
    #expect(ring.segments.map(\.role) == [.success] && ring.number == 3 && ring.label == "ativas")
    #expect(!ring.forYou)
    #expect(self.ring(working: 1).label == "ativa")
  }

  @Test func workingAndUnreadSplitTheRingAndTheCentreCountsTheUnread() {
    // The capture of 30/10: 2 unread and 2 working read "2 para você" over a ring that was all orange.
    let ring = ring(working: 2, unread: 2)
    #expect(ring.segments.map(\.role) == [.primary, .textSecondary])
    #expect(shares(ring) == [0.5, 0.5])
    #expect(ring.number == 2 && ring.label == "para você" && ring.forYou)
  }

  @Test func questionWorkingAndUnread() {
    let ring = ring(working: 2, question: 1, unread: 1)
    #expect(ring.segments.map(\.state) == [.question, .unread, .working])
    #expect(ring.segments.map(\.role) == [.accent, .primary, .textSecondary])
    #expect(shares(ring) == [0.25, 0.25, 0.5])
    #expect(ring.number == 2)
  }

  @Test func nothingDrawsOnlyTheTrack() {
    let ring = ring()
    #expect(ring.segments.isEmpty && ring.number == 0 && ring.arcs(spacing: 10).isEmpty)
    #expect(AgentsStatusRing(counts: nil).segments.isEmpty)
    #expect(AgentsStatusRing.track() == (-90, 270))
    #expect(AgentsStatusRing.track(opening: 80) == (130, 410))
  }

  @Test func everyStateHasItsLegendColorInAFixedOrder() {
    let ring = ring(working: 1, question: 1, permission: 1, failed: 1, unread: 1)
    #expect(ring.segments.map(\.state) == [.question, .permission, .failed, .unread, .working])
    #expect(ring.segments.map(\.role) == [.accent, .warning, .error, .primary, .textSecondary])
    // Failures have their own red segment and count in "para você", like the counters.
    #expect(ring.number == 4)
  }

  @Test func eachSessionCountsOnceSoTheCentreIsTheColoredSegments() {
    // The backend gives every top-level session one status (question > permission > failed > working > unread), so
    // the segments add up to the sessions and the centre is everything but `trabalhando`.
    for (working, question, permission, failed, unread) in [(2, 0, 0, 0, 2), (3, 1, 0, 0, 3), (1, 1, 1, 2, 1), (0, 0, 0, 1, 2)] {
      let ring = ring(working: working, question: question, permission: permission, failed: failed, unread: unread)
      #expect(ring.total == working + question + permission + failed + unread)
      #expect(ring.number == ring.segments.filter { $0.state != .working }.reduce(0) { $0 + $1.count })
    }
  }

  @Test func olderBackendKeepsTheFinishedFallbackGrayAndDimmed() {
    let ring = ring(working: 3, unread: nil, idle: 1)
    #expect(ring.segments.map(\.role) == [.success, .textSecondary] && ring.segments.map(\.dim) == [false, true])
    #expect(ring.number == 3 && ring.label == "ativas")
  }

  @Test func closedRingStartsAtTwelveWithSpacingAndOneSegmentClosesIt() {
    #expect(ring(working: 2).arcs(spacing: 10) == [.init(role: .success, dim: false, from: -90, to: 270)])
    let halves = ring(working: 2, unread: 2).arcs(spacing: 10)
    #expect(halves == [
      .init(role: .primary, dim: false, from: -85, to: 85),
      .init(role: .textSecondary, dim: false, from: 95, to: 265),
    ])
  }

  @Test func openRingLeavesTheBottomForTheMascot() {
    // 80° open at the bottom: the sweep runs from 130° to 410°, with spacing only between segments.
    let halves = ring(working: 2, unread: 2).arcs(opening: 80, spacing: 10)
    #expect(halves == [
      .init(role: .primary, dim: false, from: 130, to: 265),
      .init(role: .textSecondary, dim: false, from: 275, to: 410),
    ])
    #expect(ring(working: 1).arcs(opening: 80, spacing: 10) == [.init(role: .success, dim: false, from: 130, to: 410)])
  }

  @Test func aTinyShareNeverDrawsBackwards() {
    let arcs = ring(working: 200, unread: 1).arcs(spacing: 12)
    #expect(arcs.count == 2 && arcs.allSatisfy { $0.to >= $0.from })
  }
}
