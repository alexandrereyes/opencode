import OpenCodeKit
import SwiftUI

struct ConversationUsageBar: View {
  @Environment(\.appTheme) private var theme
  let usage: ContextUsage
  let open: () -> Void
  var body: some View {
    Button(action: open) {
      ContextUsageLine(usage: usage)
      .appFont(.caption).monospacedDigit()
      .foregroundStyle(theme.color(.textSecondary))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 3)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(usage.accessibilityLabel)
    .accessibilityHint("Ver uso da sessão")
    .accessibilityIdentifier("conversation-usage")
  }
}
