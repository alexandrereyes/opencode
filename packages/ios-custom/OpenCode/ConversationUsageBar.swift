import OpenCodeKit
import SwiftUI

struct ConversationUsageBar: View {
  @Environment(\.appTheme) private var theme
  let usage: ContextUsage
  let open: () -> Void
  var body: some View {
    Button(action: open) {
      ContextUsageLine(usage: usage, style: .metrics)
      .monospacedDigit()
      .foregroundStyle(theme.color(.textSecondary))
      .padding(.leading, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 40)
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
