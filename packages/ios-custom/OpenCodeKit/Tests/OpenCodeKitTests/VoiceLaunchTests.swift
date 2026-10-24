import Testing
@testable import OpenCodeKit

struct VoiceLaunchTests {
  @Test func activeOrClosingCallOnlyAcknowledges() {
    for phase in [VoicePhase.connecting, .listening, .speaking, .interrupted, .reconnecting, .offline] {
      #expect(VoiceLaunch.plan(phase: phase, busy: false, foreground: false, microphone: .granted,
        activitiesEnabled: true) == .acknowledge)
    }
    #expect(VoiceLaunch.plan(phase: .idle, busy: true, foreground: true, microphone: .granted,
      activitiesEnabled: true) == .acknowledge)
  }
  @Test func idleOrFailedStartsInBackgroundWhenEverythingIsAllowed() {
    for phase in [VoicePhase.idle, .failed] {
      #expect(VoiceLaunch.plan(phase: phase, busy: false, foreground: false, microphone: .granted,
        activitiesEnabled: true) == .start(foreground: nil))
    }
  }
  @Test func missingPermissionOrLiveActivitiesNeedTheApp() {
    #expect(VoiceLaunch.plan(phase: .idle, busy: false, foreground: false, microphone: .undetermined,
      activitiesEnabled: true) == .start(foreground: .microphonePermission))
    #expect(VoiceLaunch.plan(phase: .idle, busy: false, foreground: false, microphone: .denied,
      activitiesEnabled: false) == .start(foreground: .microphonePermission))
    #expect(VoiceLaunch.plan(phase: .idle, busy: false, foreground: false, microphone: .granted,
      activitiesEnabled: false) == .start(foreground: .liveActivitiesDisabled))
  }
  @Test func visibleAppStartsWhereItIs() {
    #expect(VoiceLaunch.plan(phase: .idle, busy: false, foreground: true, microphone: .undetermined,
      activitiesEnabled: false) == .start(foreground: nil))
  }
}
