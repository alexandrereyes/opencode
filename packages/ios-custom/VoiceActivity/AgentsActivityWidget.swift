import ActivityKit
import OpenCodeKit
import SwiftUI
import WidgetKit

/// "Agentes": one informative Live Activity per server, with no buttons or intents. Tapping opens the app.
struct AgentsActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: AgentsActivityAttributes.self) { context in
      AgentsLockScreenView(attributes: context.attributes, state: context.state)
        .activityBackgroundTint(context.attributes.color(.background))
        .activitySystemActionForegroundColor(context.attributes.color(.textStrong))
        .widgetURL(AgentsDeepLink.card(context.state, serverKey: context.attributes.serverKey).url)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.bottom) {
          AgentsIslandExpanded(attributes: context.attributes, state: context.state).padding(.horizontal, 6)
        }
      } compactLeading: {
        AgentsMascot(attributes: context.attributes).frame(width: 24, height: 20)
      } compactTrailing: {
        AgentsCompactTrailing(attributes: context.attributes, state: context.state)
      } minimal: {
        AgentsMinimalView(attributes: context.attributes, state: context.state)
      }
      .widgetURL(AgentsDeepLink.card(context.state, serverKey: context.attributes.serverKey).url)
      .keylineTint(context.attributes.color(.primary))
    }
  }
}
