import ActivityKit
import Foundation
import OpenCodeKit

@MainActor final class VoiceActivityDriver {
  private var sessionID: String?
  private var updates: Task<Void, Never>?
  private var last: VoiceActivityAttributes.ContentState?
  private var unavailable = false
  init() {
    let leftovers = Self.existingIDs()
    updates = Task { await Self.finish(leftovers) }
  }

  func update(id: UUID, state: VoiceState, theme: AppTheme,
    action: @escaping (VoiceActivityAction) async -> Void) {
    VoiceActivityRouter.sessionID = id.uuidString
    VoiceActivityRouter.handler = action
    guard ActivityAuthorizationInfo().areActivitiesEnabled, !unavailable else { return }
    let content = Self.content(state: state, theme: theme)
    guard content != last else { return }
    last = content
    if sessionID == nil {
      do {
        _ = try Activity.request(attributes: VoiceActivityAttributes(sessionID: id.uuidString, started: .now),
          content: ActivityContent(state: content, staleDate: nil), pushType: nil)
        sessionID = id.uuidString
      } catch { unavailable = true }
      return
    }
    let prior = updates
    let sessionID = sessionID
    updates = Task {
      await prior?.value
      guard !Task.isCancelled else { return }
      await Self.apply(content, sessionID: sessionID)
    }
  }
  static func content(state: VoiceState, theme: AppTheme) -> VoiceActivityAttributes.ContentState {
    let roles: [ThemeRole] = [.background, .textStrong, .textSecondary, .accent, .error]
    let colors = Dictionary(uniqueKeysWithValues: roles.map { role in
      let color = theme.value(role)
      return (String(role.rawValue), [color.red, color.green, color.blue, color.opacity])
    })
    return VoiceActivityAttributes.ContentState(label: state.label, muted: state.muted,
      working: state.masterWorking, speaking: state.phase == .speaking, colors: colors)
  }
  func end() async {
    VoiceActivityRouter.handler = nil; VoiceActivityRouter.sessionID = nil
    updates?.cancel(); await updates?.value; updates = nil
    if let sessionID { await Self.finish([sessionID]) }
    sessionID = nil; last = nil; unavailable = false
  }
  private nonisolated static func existingIDs() -> [String] {
    Activity<VoiceActivityAttributes>.activities.map { $0.attributes.sessionID }
  }
  private nonisolated static func apply(_ content: VoiceActivityAttributes.ContentState, sessionID: String?) async {
    guard let activity = Activity<VoiceActivityAttributes>.activities.first(where: { $0.attributes.sessionID == sessionID }) else { return }
    await activity.update(ActivityContent(state: content, staleDate: nil))
  }
  private nonisolated static func finish(_ ids: [String]) async {
    for activity in Activity<VoiceActivityAttributes>.activities where ids.contains(activity.attributes.sessionID) {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }
}
