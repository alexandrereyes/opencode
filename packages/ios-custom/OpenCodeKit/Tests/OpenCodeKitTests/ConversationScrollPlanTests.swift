import Testing

@testable import OpenCodeKit

struct ConversationScrollPlanTests {
  private let first = ConversationScrollPlan.Layout(height: 2000, width: 400, viewport: 700, bottom: 2000)
  private let grown = ConversationScrollPlan.Layout(height: 2200, width: 400, viewport: 700, bottom: 2200)

  @Test func burstWaitsForSettledLayoutAndConsumesOnce() {
    var plan = ConversationScrollPlan()
    plan.follow()
    plan.follow(animated: true)
    plan.invalidate()
    #expect(plan.consume(first, interacting: false) == nil)
    #expect(plan.consume(grown, interacting: false) == nil)
    #expect(plan.consume(grown, interacting: false) == .tail(animated: true))
    #expect(plan.consume(grown, interacting: false) == nil)
    plan.invalidate()
    #expect(plan.consume(grown, interacting: false) == nil)
    #expect(plan.consume(grown, interacting: false) == .tail(animated: false))
  }

  @Test func readingAndFollowingAreExclusive() {
    var plan = ConversationScrollPlan()
    plan.invalidate()
    #expect(plan.consume(first, interacting: false) == nil)
    plan.follow()
    #expect(plan.consume(first, interacting: false) == nil)
    #expect(plan.consume(first, interacting: false) == .tail(animated: false))
    plan.cancel()
    plan.invalidate()
    #expect(plan.consume(first, interacting: false) == nil)
    #expect(plan.consume(first, interacting: false) == .reading)
  }

  @Test func interactionCancelsEvenExplicitAnimation() {
    var plan = ConversationScrollPlan()
    plan.follow(animated: true)
    #expect(plan.consume(first, interacting: false) == nil)
    #expect(plan.consume(first, interacting: true) == nil)
    #expect(!plan.following)
    #expect(!plan.pending)
    #expect(plan.consume(first, interacting: false) == nil)
  }

  @Test func navigationCancelsPendingWorkAndItsAnimation() {
    var plan = ConversationScrollPlan()
    plan.follow(animated: true)
    #expect(plan.consume(first, interacting: false) == nil)
    plan.cancel()
    plan.follow()
    #expect(plan.consume(first, interacting: false) == nil)
    #expect(plan.consume(first, interacting: false) == .tail(animated: false))
  }

  @Test func continuousGrowthConsumesOneSettledLayoutPerRequest() {
    var plan = ConversationScrollPlan()
    plan.follow()
    (1...50).forEach { index in
      plan.invalidate()
      let layout = ConversationScrollPlan.Layout(height: Double(index * 1000), width: 400, viewport: 700, bottom: Double(index * 1000))
      #expect(plan.consume(layout, interacting: false) == nil)
      #expect(plan.consume(layout, interacting: false) == .tail(animated: false))
      #expect(plan.consume(layout, interacting: false) == nil)
    }
  }

  @Test func notificationsWhilePendingDoNotRestartSettlement() {
    var plan = ConversationScrollPlan()
    plan.follow()
    #expect(plan.consume(first, interacting: false) == nil)
    plan.follow()
    plan.invalidate()
    #expect(plan.consume(first, interacting: false) == .tail(animated: false))
  }
}
