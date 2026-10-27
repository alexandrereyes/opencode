import OpenCodeKit
import SwiftUI

struct SessionDirectoryLine: View {
  @Environment(\.appTheme) private var theme
  let label: SessionDirectoryLabel?

  var body: some View {
    if let label {
      SessionDirectoryLayout {
        Text(label.path).lineLimit(1).truncationMode(.middle)
        if let branch = label.branch {
          Text(" · ").fixedSize().foregroundStyle(theme.color(.textSecondary))
          Text(branch).lineLimit(1).truncationMode(.tail).foregroundStyle(theme.color(.textSecondary))
        }
      }
      .appFont(.path)
      .foregroundStyle(theme.color(.textMuted))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label.accessibilityLabel)
    }
  }
}

private struct SessionDirectoryLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    CGSize(
      width: proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width },
      height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard let path = subviews.first else { return }
    guard subviews.count == 3 else {
      path.place(
        at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
      return
    }
    let separator = subviews[1].sizeThatFits(.unspecified).width
    let available = max(0, bounds.width - separator)
    let branch = min(
      subviews[2].sizeThatFits(.unspecified).width,
      max(available * 0.4, available - path.sizeThatFits(.unspecified).width))
    let width = min(path.sizeThatFits(.unspecified).width, available - branch)
    path.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: bounds.height))
    subviews[1].place(at: CGPoint(x: bounds.minX + width, y: bounds.minY), proposal: .unspecified)
    subviews[2].place(
      at: CGPoint(x: bounds.minX + width + separator, y: bounds.minY),
      proposal: ProposedViewSize(width: branch, height: bounds.height))
  }
}

private struct SessionRowDateKey: EnvironmentKey {
  static let defaultValue = Date.now
}
extension EnvironmentValues {
  var sessionRowDate: Date {
    get { self[SessionRowDateKey.self] }
    set { self[SessionRowDateKey.self] = newValue }
  }
}
private struct SessionRowTimeline: ViewModifier {
  @Environment(\.scenePhase) private var scenePhase
  let active: Bool
  func body(content: Content) -> some View {
    TimelineView(SessionRowSchedule(active: active && scenePhase == .active)) { context in
      content.environment(\.sessionRowDate, context.date)
    }
  }
}
struct SessionRowSchedule: TimelineSchedule {
  let active: Bool
  func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
    guard active else { return AnySequence([startDate]) }
    return AnySequence(
      PeriodicTimelineSchedule(from: startDate, by: 60).entries(from: startDate, mode: mode))
  }
}
extension View {
  func sessionRowTimeline(active: Bool = true) -> some View {
    modifier(SessionRowTimeline(active: active))
  }
}

struct SessionRowTime: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  let at: Double
  var unread = false
  var body: some View {
    let time = SessionList.relativeTime(at, now: now)
    Text(time.label)
      .appFont(.secondary).monospacedDigit()
      .foregroundStyle(theme.color(unread ? .textAccent : .textSecondary))
      .fixedSize()
      .accessibilityLabel(time.accessibilityLabel)
  }
}
