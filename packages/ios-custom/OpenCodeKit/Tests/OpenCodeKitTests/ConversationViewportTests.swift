import Testing

@testable import OpenCodeKit

struct ConversationViewportTests {
  @Test func jumpUsesStrictViewportThreshold() {
    #expect(!ConversationScrollPlan.Viewport(height: 2000, offset: 600, viewport: 700).jumpToLatest)
    #expect(ConversationScrollPlan.Viewport(height: 2000, offset: 599, viewport: 700).jumpToLatest)
  }

  @Test func shortViewportStillRequiresFourHundredPoints() {
    #expect(!ConversationScrollPlan.Viewport(height: 1000, offset: 300, viewport: 300).jumpToLatest)
    #expect(ConversationScrollPlan.Viewport(height: 1000, offset: 299, viewport: 300).jumpToLatest)
  }

  @Test func noOverflowAndBottomBounceHaveNoIndicator() {
    for height in [0.0, 699, 700, 701] {
      #expect(!ConversationScrollPlan.Viewport(height: height, offset: 0, viewport: 700).jumpToLatest)
    }
    #expect(!ConversationScrollPlan.Viewport(height: 2000, offset: 1400, viewport: 700).jumpToLatest)
  }

  @Test func dismissalIsGeometryNotAConsumedUnreadBoundary() {
    let history = ConversationScrollPlan.Viewport(height: 2000, offset: 200, viewport: 700)
    #expect(history.jumpToLatest)
    #expect(!ConversationScrollPlan.Viewport(height: 2000, offset: 1300, viewport: 700).jumpToLatest)
    #expect(history.jumpToLatest)
    #expect(!ConversationScrollPlan.Viewport(height: 1000, offset: 200, viewport: 700).jumpToLatest)
  }

  @Test func growthCanRevealJumpWithoutAnyMessageCounter() {
    #expect(!ConversationScrollPlan.Viewport(height: 1200, offset: 500, viewport: 700).jumpToLatest)
    #expect(!ConversationScrollPlan.Viewport(height: 1800, offset: 500, viewport: 700).jumpToLatest)
    #expect(ConversationScrollPlan.Viewport(height: 2100, offset: 500, viewport: 700).jumpToLatest)
  }

  @Test func nearTheEndDoesNotResumeFollowing() {
    #expect(!ConversationScrollPlan.Viewport(height: 2000, offset: 1299, viewport: 700).atEnd)
    #expect(ConversationScrollPlan.Viewport(height: 2000, offset: 1299.5, viewport: 700).atEnd)
    #expect(ConversationScrollPlan.Viewport(height: 2000, offset: 1300, viewport: 700).atEnd)
    #expect(ConversationScrollPlan.Viewport(height: 200, offset: 0, viewport: 700).atEnd)
  }

  @Test func arrivalIncludesShrinkingContentAndGrowingViewport() {
    let reading = ConversationScrollPlan.Viewport(height: 2000, offset: 1000, viewport: 700)
    #expect(ConversationScrollPlan.Viewport(height: 1700, offset: 1000, viewport: 700).arrivedAtEnd(from: reading))
    #expect(ConversationScrollPlan.Viewport(height: 2000, offset: 1000, viewport: 1000).arrivedAtEnd(from: reading))
    #expect(ConversationScrollPlan.Viewport(height: 2000, offset: 1300, viewport: 700).arrivedAtEnd(from: reading))
    #expect(!ConversationScrollPlan.Viewport(height: 2000, offset: 1200, viewport: 700).arrivedAtEnd(from: reading))
  }

  @Test func upwardIntentWithinEndToleranceDoesNotRepin() {
    let end = ConversationScrollPlan.Viewport(height: 2000, offset: 1300, viewport: 700)
    #expect(!ConversationScrollPlan.Viewport(height: 2000, offset: 1299.8, viewport: 700).arrivedAtEnd(from: end))
  }
}
