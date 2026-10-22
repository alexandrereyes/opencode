import XCTest

@MainActor extension XCUIApplication {
  func revealSessionRow(_ row: XCUIElement) {
    let list = collectionViews.firstMatch
    let deadline = Date().addingTimeInterval(60)
    if !row.exists { list.swipeDown(velocity: .fast) }
    while Date() < deadline {
      let top = navigationBars.firstMatch.frame.maxY
      let bar = tabBars.firstMatch.frame
      // AX can report prefetched rows as hittable under the floating bar and its
      // accessory. Reserve one bar-height above it before tapping a semantic row.
      let bottom = bar.minY - bar.height
      if row.exists {
        let frame = row.frame
        if row.isHittable && frame.minY >= top && frame.maxY <= bottom { return }
        if frame.minY < top {
          list.swipeDown(velocity: .slow)
          continue
        }
      }
      list.swipeUp(velocity: .slow)
    }
    XCTFail("A sessão não ficou visível acima da barra de abas.")
  }
}
