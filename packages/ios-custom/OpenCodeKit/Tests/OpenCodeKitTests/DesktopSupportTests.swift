import Foundation
import Testing

@testable import OpenCodeKit

@Suite struct DesktopSupportTests {
  @Test func neighborsFollowTheColumnOrderAndStopAtTheEnds() {
    let ids = ["a", "b", "c"]
    #expect(SessionNavigation.neighbor(ids, current: "b", offset: 1) == "c")
    #expect(SessionNavigation.neighbor(ids, current: "b", offset: -1) == "a")
    #expect(SessionNavigation.neighbor(ids, current: "c", offset: 1) == nil)
    #expect(SessionNavigation.neighbor(ids, current: "a", offset: -1) == nil)
  }

  @Test func neighborsWithoutACurrentRowStartAtAnEnd() {
    let ids = ["a", "b", "c"]
    #expect(SessionNavigation.neighbor(ids, current: nil, offset: 1) == "a")
    #expect(SessionNavigation.neighbor(ids, current: "gone", offset: -1) == "c")
    #expect(SessionNavigation.neighbor([], current: nil, offset: 1) == nil)
    #expect(SessionNavigation.neighbor(ids, current: "a", offset: 0) == nil)
  }

  @Test func notificationsCarryTheBannerLabelAndTheAnswer() {
    let replied = SessionAlertNotification(
      title: "App Mac",
      content: SessionAlertContent(kind: .succeeded, work: SessionAlertWork(agents: 1, tasks: 0), preview: "Pronto."))
    #expect(replied.title == "App Mac")
    #expect(replied.body == "Respondeu · 1 agente rodando\nPronto.")
    let permission = SessionAlertNotification(title: "Docs", content: SessionAlertContent(kind: .permission))
    #expect(permission.body == "Precisa de você")
    let failed = SessionAlertNotification(title: "Docs", content: SessionAlertContent(kind: .failed, preview: "x"))
    #expect(failed.body == "Falhou")
  }

  @Test func theBadgeCountsOnlyPendingRequests() {
    #expect(SessionAlertNotification.badge(0) == nil)
    #expect(SessionAlertNotification.badge(3) == "3")
  }

  @Test func shellOutputStartsNearTheEndAndAppendsByCursor() {
    var log = ShellOutputLog(limit: 10)
    log.start(size: 4)
    #expect(log.cursor == 0)
    #expect(!log.clipped)
    log.append(ShellOutput(output: "ab\n", cursor: 3, size: 3, truncated: false))
    log.append(ShellOutput(output: "c\n", cursor: 5, size: 5, truncated: false))
    #expect(log.text == "ab\nc\n")
    #expect(log.cursor == 5)
    // A stale chunk (an older cursor) never duplicates text.
    log.append(ShellOutput(output: "c\n", cursor: 4, size: 5, truncated: false))
    #expect(log.text == "ab\nc\n")

    var long = ShellOutputLog(limit: 10)
    long.start(size: 100)
    #expect(long.cursor == 90)
    #expect(long.clipped)
  }

  @Test func macKeysBecomeResourceInput() {
    typealias Keys = ResourceKeyMapping
    #expect(Keys.input(keyCode: 36, characters: "\r", plain: "\r", modifiers: []) == .key("Enter"))
    #expect(Keys.input(keyCode: 51, characters: "\u{7F}", plain: "\u{7F}", modifiers: []) == .key("Backspace"))
    #expect(Keys.input(keyCode: 48, characters: "\t", plain: "\t", modifiers: .shift) == .key("Tab", modifiers: ["Shift"]))
    #expect(Keys.input(keyCode: 123, characters: "\u{F702}", plain: "\u{F702}", modifiers: []) == .key("ArrowLeft"))
    #expect(Keys.input(keyCode: 0, characters: "a", plain: "a", modifiers: []) == .text("a"))
    #expect(Keys.input(keyCode: 0, characters: "A", plain: "a", modifiers: .shift) == .text("A"))
    // Option types characters on a Mac keyboard; Control is a shortcut for the resource.
    #expect(Keys.input(keyCode: 31, characters: "ø", plain: "o", modifiers: .option) == .text("ø"))
    #expect(Keys.input(keyCode: 0, characters: "\u{01}", plain: "a", modifiers: .control) == .key("a", modifiers: ["Control"]))
    // Command shortcuts and function keys without a DOM name stay with the Mac.
    #expect(Keys.input(keyCode: 9, characters: "v", plain: "v", modifiers: .command) == nil)
    #expect(Keys.input(keyCode: 122, characters: "\u{F704}", plain: "\u{F704}", modifiers: []) == nil)
  }

  @Test func wrappedMarkdownJoinsItsSoftBreaks() {
    let text = """
      # Title
      First line of a paragraph
      that continues here.

      - An item
        wrapped in two lines
      - Another item
      > A quote
      ```swift
      let a = 1
      let b = 2
      ```
      | a | b |
      | - | - |
      Hard break here\u{20}\u{20}
      next line
      """
    #expect(MarkdownSoftBreaks.unwrap(text) == """
      # Title
      First line of a paragraph that continues here.

      - An item wrapped in two lines
      - Another item
      > A quote
      ```swift
      let a = 1
      let b = 2
      ```
      | a | b |
      | - | - |
      Hard break here\u{20}\u{20}
      next line
      """)
  }

  @Test func longMarkdownSplitsAtBlankLinesOutsideFences() {
    let text = "a\nb\n\nc\n```\nx\n\ny\n```\n\nd"
    #expect(MarkdownSoftBreaks.sections(text, lines: 2) == ["a\nb", "c\n```\nx\n\ny\n```", "d"])
    #expect(MarkdownSoftBreaks.sections("one", lines: 2) == ["one"])
  }

  @Test func shellOutputKeepsWholeLinesWithinItsLimit() {
    var log = ShellOutputLog(limit: 8)
    log.append(ShellOutput(output: "first\nsecond\nthird\n", cursor: 19, size: 19, truncated: false))
    #expect(log.text == "third\n")
    #expect(log.clipped)
    #expect(log.cursor == 19)
  }
}
