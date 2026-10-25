import OpenCodeKit
import SwiftUI

/// The line below the composer card: the agent (moved out of the card's control row so the compact microphone fits
/// beside Send) and, in a measured conversation, its context and cache usage. The agent keeps its width; when space
/// runs out the usage folds into two lines.
struct ComposerFooter: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationStore
  let draft: ConversationDraft
  var usage: ContextUsage? = nil
  var openUsage: () -> Void = {}
  var body: some View {
    HStack(spacing: 6) {
        agent.layoutPriority(1)
        if let usage {
          Text("·").appFont(.metrics).accessibilityHidden(true)
          Button(action: openUsage) {
            ContextUsageLine(usage: usage, style: .metrics)
              .monospacedDigit()
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityElement(children: .ignore)
          .accessibilityAddTraits(.isButton)
          .accessibilityLabel(usage.accessibilityLabel)
          .accessibilityHint("Ver uso da sessão")
          .accessibilityIdentifier("conversation-usage")
        } else {
          Spacer(minLength: 0)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .foregroundStyle(theme.color(.textSecondary))
    .padding(.leading, 8)
    .frame(height: 40)
  }
  @ViewBuilder private var agent: some View {
    if store.isChild || store.masterMode {
      Text(store.childAgentName).appFont(.chrome, weight: .semibold).lineLimit(1)
        .accessibilityLabel("Agente: \(store.childAgentName)")
        .accessibilityIdentifier("child-agent")
    } else {
      Button {
        draft.focused = false
        draft.choosingAgent = true
      } label: {
        HStack(spacing: 3) {
          Text(store.selectedAgent(draft)).appFont(.chrome, weight: .semibold).lineLimit(1)
          Image(systemName: "chevron.down").appFont(.mcp)
        }
        .frame(minWidth: 44, maxHeight: .infinity, alignment: .leading).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(draft.sending || draft.importing)
      .accessibilityLabel("Agente")
      .accessibilityValue(store.selectedAgent(draft))
      .accessibilityHint("Trocar o agente")
      .accessibilityIdentifier("agent-picker")
    }
  }
}
