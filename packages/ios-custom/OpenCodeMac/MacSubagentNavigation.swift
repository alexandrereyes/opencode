import OpenCodeKit
import SwiftUI

/// Shared latest identity for the banner and tree. Session fields reflect the latest committed selection;
/// while the transcript is streaming its most recent step is the more precise source.
@MainActor enum MacSubagentIdentity {
  static func agent(_ store: ConversationStore) -> String {
    let id = store.messages.reversed().first { $0.type == .assistant && $0.agent != nil }?.agent ?? store.session?.agent
    return store.agents.first { $0.id == id }?.name ?? id ?? "Subagente"
  }
  static func detail(_ store: ConversationStore) -> String {
    let model = store.messages.reversed().first { $0.type == .assistant && $0.model != nil }?.model ?? store.session?.model
    return [agent(store), store.modelLabel(model), model != nil && (model?.variant == nil || model?.variant == "default") ? "padrão" : ""]
      .filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

struct MacSubagentBanner: View {
  @Environment(\.appTheme) private var theme
  let conversation: ConversationStore
  let parentTitle: String
  let back: () -> Void
  var body: some View {
    HStack(spacing: 13) {
      AgentPixels(color: theme.color(.accent), size: 24, running: conversation.executing, grid: true)
      VStack(alignment: .leading, spacing: 3) {
        Text("SUBAGENTE").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(theme.color(.accent))
        Text(conversation.session?.displayTitle ?? "Subagente").font(.system(size: 14, weight: .medium)).lineLimit(1)
          .foregroundStyle(theme.color(.textStrong))
        Text(MacSubagentIdentity.detail(conversation)).font(.system(size: 11)).lineLimit(1)
          .foregroundStyle(theme.color(.textSecondary))
      }
      Spacer(minLength: 12)
      Button(action: back) {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left")
          Text("Voltar para \(parentTitle)").lineLimit(1)
          Text("⌘[").fixedSize()
        }.font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 5)
          .overlay { Capsule().strokeBorder(theme.color(.accent).opacity(0.5), lineWidth: 0.7) }
      }.buttonStyle(.plain).foregroundStyle(theme.color(.accent)).help("Voltar para \(parentTitle) (⌘[)")
        .accessibilityIdentifier("subagent-back").frame(maxWidth: 250)
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.color(.accent).opacity(0.08))
    .overlay(alignment: .leading) { Rectangle().fill(theme.color(.accent)).frame(width: 3) }
    .overlay(alignment: .bottom) { ContextHairline() }
    .accessibilityIdentifier("subagent-banner")
  }
}

/// Only the currently opened ancestry is expanded; returning to its root removes the branch.
struct MacSubagentTree: View {
  @Environment(\.appTheme) private var theme
  let store: SessionStore
  let runtime: MacWindowRuntime
  let rootID: String
  private var path: [Session] {
    guard runtime.selection.sessionID == rootID, let child = runtime.selection.childID else { return [] }
    var sessions = Dictionary(store.entries.map { ($0.session.id, $0.session) }, uniquingKeysWith: { a, _ in a })
    for session in store.liveConversation(rootID)?.children ?? [] { sessions[session.id] = session }
    if let current = store.liveConversation(child)?.session { sessions[child] = current }
    return SubagentNavigation.path(root: rootID, child: child, sessions: Array(sessions.values))
  }
  var body: some View {
    #if DEBUG
    let _ = MacPerf.count("MacSubagentTree")
    #endif
    VStack(spacing: 3) {
      ForEach(Array(path.enumerated()), id: \.element.id) { depth, session in
        Button { runtime.selection.childID = session.id } label: {
          HStack(spacing: 8) {
            AgentPixels(color: theme.color(.accent), size: 16, running: store.active.contains(session.id), grid: true)
            VStack(alignment: .leading, spacing: 3) {
              Text(session.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(theme.color(.textStrong))
              Text((store.liveConversation(session.id).map(MacSubagentIdentity.agent) ?? session.agent ?? "Subagente")
                + " · " + state(session)).font(.system(size: 10)).lineLimit(1).foregroundStyle(theme.color(.textSecondary))
            }
            Spacer(minLength: 0)
          }
          .padding(8).background(theme.color(.accent).opacity(runtime.selection.childID == session.id ? 0.17 : 0.06),
            in: RoundedRectangle(cornerRadius: 9))
          .padding(.leading, CGFloat(depth + 1) * 14)
          .overlay(alignment: .leading) {
            Path { path in path.move(to: CGPoint(x: 5, y: 0)); path.addLine(to: CGPoint(x: 5, y: 24)); path.addLine(to: CGPoint(x: 14, y: 24)) }
              .stroke(theme.color(.accent).opacity(0.4), lineWidth: 0.7).padding(.leading, CGFloat(depth) * 14)
          }
        }.buttonStyle(.plain).accessibilityIdentifier("subagent-tree-" + session.id)
      }
    }.padding(.top, path.isEmpty ? 0 : 6)
  }
  private func state(_ session: Session) -> String {
    let entry = store.entries.first { $0.session.id == session.id }
    if entry?.permissionAt != nil || entry?.questionAt != nil { return "precisa de você" }
    if store.active.contains(session.id) { return "trabalhando" }
    return session.outcome == .failed ? "falhou" : "concluído"
  }
}
