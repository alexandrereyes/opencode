import XCTest

@MainActor extension XCUIApplication {
  func transcriptViewport(_ transcript: XCUIElement) -> CGRect {
    let bounds = transcript.frame
    let top = descendants(matching: .any).matching(identifier: "conversation-pinned-user")
      .allElementsBoundByIndex.map(\.frame)
      .filter { $0.minY < bounds.maxY && $0.maxY > bounds.minY }
      .min(by: { $0.minY < $1.minY })?.maxY ?? bounds.minY
    return CGRect(x: bounds.minX, y: top + 4, width: bounds.width, height: bounds.maxY - top - 8)
  }

  func dragTranscript(_ transcript: XCUIElement, viewport: CGRect, delta: CGFloat) {
    let distance = min(120, max(20, abs(delta)), viewport.height * 0.7) * (delta < 0 ? -1.0 : 1.0)
    let start = viewport.midY - distance / 2 - transcript.frame.minY
    // Stay in the gutter and inside the usable viewport; holding prevents a fling.
    transcript.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 32, dy: start))
      .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: 32, dy: start + distance)), withVelocity: .slow, thenHoldForDuration: 0.2)
  }
}
