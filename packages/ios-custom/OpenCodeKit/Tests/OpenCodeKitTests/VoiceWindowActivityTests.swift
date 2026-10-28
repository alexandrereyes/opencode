import Foundation
import Testing
@testable import OpenCodeKit

@Test func voiceOutlivesAllDesktopWindowsAndEndsWhenIdle() {
  var activity = VoiceWindowActivity()
  let first = UUID(), second = UUID()
  #expect(!activity.requiresEvents(calling: false))
  activity.window(first, visible: true)
  activity.window(second, visible: true)
  activity.window(first, visible: false)
  #expect(activity.requiresEvents(calling: false))
  activity.window(second, visible: false)
  #expect(activity.requiresEvents(calling: true))
  #expect(!activity.requiresEvents(calling: false))
  activity.window(first, visible: true)
  activity.window(first, visible: true)
  activity.window(first, visible: false)
  #expect(!activity.requiresEvents(calling: false))
}
